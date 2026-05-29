import Foundation
import Observation
import simd
#if canImport(UIKit)
import UIKit
#endif

/// Owns the capture session state and coordinates the sensor services. Built so
/// the sensor/location/upload collaborators are injected (protocols), keeping it
/// unit-testable without device hardware.
@Observable
@MainActor
final class CaptureViewModel {
    // MARK: - inputs
    var tokenInput: String = ""
    var jobIDInput: String = ""

    // MARK: - flow state
    private(set) var state: CaptureSessionState = .tokenEntry
    private(set) var captures: [CaptureEntry] = []
    private(set) var uploadProgress: Double = 0
    private(set) var shareURL: String?
    private(set) var errorMessage: String?
    private(set) var gpsReady: Bool = false

    /// The on-disk `.zip` produced by the local-save recovery path, ready for
    /// export via the document picker. Set when the user saves the bundle locally.
    private(set) var savedBundleURL: URL?

    /// Guards against a second upload being kicked off while one is in flight
    /// (e.g. a double-tap on the final capture, or Retry mashed twice).
    private var uploadInFlight = false

    /// Stable across upload retries — the session.json idempotency key.
    let sessionID = UUID().uuidString
    private let startedAt = Date()

    /// Immutable snapshot of the upload target (token + job id), taken when the
    /// capture flow leaves token entry. The uploader and manifest read THIS, not
    /// the mutable `tokenInput`/`jobIDInput`, so a deep link or UI edit arriving
    /// after capture has started can never redirect the finished bundle to a
    /// different job. Nil until `startSetupCheck` snapshots it.
    private var activeCredentials: (token: String, jobID: String)?

    // MARK: - collaborators
    private let sensors: CaptureSensing?
    private let location: LocationProviding
    private let uploader: MultipartUploader
    private let archiver: BundleArchiver

    // Built bundle (set at session end).
    private var photoData: [Data] = []
    private var depthData: [Data] = []
    private var meshResult: MeshExportResult?
    private var originFix: LocationFix?

    init(sensors: CaptureSensing?,
         location: LocationProviding,
         uploader: MultipartUploader = MultipartUploader(),
         archiver: BundleArchiver = BundleArchiver()) {
        self.sensors = sensors
        self.location = location
        self.uploader = uploader
        self.archiver = archiver
    }

    // MARK: - token entry

    var canStart: Bool {
        TokenValidator.isValid(tokenInput) && TokenValidator.isValidJobID(jobIDInput)
    }

    func applyDeepLink(_ url: URL) {
        // Only honor a deep link while we're still on the token-entry screen. A
        // `rooftrace://capture?...` link arriving mid-capture must NOT mutate the
        // credentials — otherwise it could redirect the completed bundle to an
        // attacker's job. Ignore it once the flow has moved past token entry.
        guard state == .tokenEntry else { return }
        guard let parsed = TokenValidator.parseDeepLink(url) else { return }
        tokenInput = parsed.token
        if let jobID = parsed.jobID { jobIDInput = jobID }
    }

    func startSetupCheck() {
        guard canStart else { return }
        // Snapshot the upload target the moment we leave token entry. From here
        // on the uploader reads this immutable snapshot, so later edits to the
        // input fields (or a stray deep link) can't change the active target.
        activeCredentials = (token: tokenInput, jobID: jobIDInput)
        location.requestAuthorization()
        _ = state.advance(to: .setupCheck)
    }

    // MARK: - setup check

    func runSetupCheck() async {
        guard let sensors else {
            // No sensors injected (e.g. simulator) — treat as unsupported.
            _ = state.advance(to: .lidarUnsupported)
            errorMessage = "This app requires an iPhone Pro or iPad Pro with LiDAR."
            return
        }
        sensors.startSession()
        let ok = await sensors.probeSceneDepth(timeout: 5.0)
        if ok {
            _ = state.advance(to: .capturePrompt(0))
            // Kick off the origin GPS fix in the background.
            Task { await acquireOrigin() }
        } else {
            _ = state.advance(to: .lidarUnsupported)
            errorMessage = "This app requires an iPhone Pro or iPad Pro with LiDAR."
        }
    }

    private func acquireOrigin() async {
        originFix = await location.acquireOriginFix(targetAccuracyM: 10.0, timeout: 30.0)
        gpsReady = (originFix?.horizontalAccuracyM ?? .greatestFiniteMagnitude) <= 10.0
    }

    // MARK: - capture

    var currentPromptIndex: Int? {
        if case let .capturePrompt(i) = state { return i }
        return nil
    }

    var currentPrompt: PromptStep? {
        currentPromptIndex.map { PromptLibrary.step(at: $0) }
    }

    /// Performs one capture at the current prompt and advances. Returns false on error.
    @discardableResult
    func capture() -> Bool {
        guard let index = currentPromptIndex, let sensors else { return false }
        let prompt = PromptLibrary.step(at: index)
        do {
            let frame = try sensors.captureFrame()
            let depthPNG = try DepthMapEncoder.encodePNG(
                depthsMeters: frame.depthMeters, width: frame.depthWidth, height: frame.depthHeight)
            let entry = CaptureEntry(
                captureIndex: index,
                promptLabel: prompt.label,
                photoFilename: String(format: "photo_%02d.jpg", index),
                depthFilename: String(format: "depth_%02d.png", index),
                timestamp: CaptureSessionManifest.iso8601.string(from: Date()),
                gps: (location.latestFix ?? originFix)?.gpsFix
                    ?? GPSFix(latitude: 0, longitude: 0, altitudeM: 0,
                              horizontalAccuracyM: 9999, verticalAccuracyM: 9999),
                cameraPose: CameraPose(intrinsics: frame.intrinsics, worldToCamera: frame.worldToCamera),
                attitude: AttitudeQuaternion(quaternion: frame.attitude,
                                             referenceFrame: frame.attitudeReferenceFrame),
                depthRangeM: DepthMapEncoder.depthRangeMeters(frame.depthMeters)
            )
            captures.append(entry)
            photoData.append(frame.jpeg)
            depthData.append(depthPNG)

            if index == CaptureSessionState.promptCount - 1 {
                // Last prompt: transition to .uploading synchronously so a
                // double-tap can't append a 9th capture or fire a second upload
                // (the .capturePrompt(7) -> .uploading edge fires exactly once).
                guard state.advance(to: .uploading) else { return false }
                Task { await finishAndUpload() }
            } else {
                _ = state.advance(to: .capturePrompt(index + 1))
            }
            return true
        } catch {
            errorMessage = "Capture failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - finish + upload

    private func finishAndUpload() async {
        guard let sensors else { return }
        // State is already `.uploading` (advanced synchronously in `capture()`).

        let meshExport = await sensors.exportWorldMesh()
        switch meshExport {
        case .success(let result):
            meshResult = result
        case .failure(let error):
            errorMessage = "Mesh export failed: \(error)"
            _ = state.advance(to: .uploadFailed)
            return
        }
        await performUpload()
    }

    func retryUpload() async {
        guard state == .uploadFailed, !uploadInFlight else { return }
        _ = state.advance(to: .uploading)
        await performUpload()
    }

    /// Local-save recovery path: writes the assembled bundle to a `.zip` on disk
    /// and advances to `.bundleSaved`. The view then presents the document picker
    /// (`savedBundleURL`) so the user can move the archive out via the Files app
    /// and upload it later. No-op unless the upload has failed.
    func saveBundleLocally() async {
        guard state == .uploadFailed, let mesh = meshResult else { return }
        let manifest = buildManifest(mesh: mesh)
        do {
            let parts = try buildParts(manifest: manifest, mesh: mesh)
            let zipURL = try archiver.archive(parts: parts, named: "rooftrace-capture-\(sessionID)")
            savedBundleURL = zipURL
            errorMessage = nil
            _ = state.advance(to: .bundleSaved)
        } catch {
            errorMessage = "Couldn't save the bundle: \(error.localizedDescription). Try Retry instead."
        }
    }

    private func performUpload() async {
        guard !uploadInFlight else { return }
        uploadInFlight = true
        defer { uploadInFlight = false }
        guard let mesh = meshResult else {
            _ = state.advance(to: .uploadFailed)
            return
        }
        let manifest = buildManifest(mesh: mesh)
        let parts: [MultipartPart]
        do {
            parts = try buildParts(manifest: manifest, mesh: mesh)
        } catch {
            errorMessage = "Failed to assemble upload: \(error.localizedDescription)"
            _ = state.advance(to: .uploadFailed)
            return
        }

        // Encode the multipart body to a temp file and stream it from disk, so
        // the full bundle (the OBJ mesh alone can be 60-120MB) never sits in RAM
        // during the upload. The file is deleted once the upload finishes.
        let encoder = MultipartEncoder()
        let bodyFileURL: URL
        do {
            bodyFileURL = try encoder.encodeToTempFile(parts)
        } catch {
            errorMessage = "Failed to assemble upload: \(error.localizedDescription)"
            _ = state.advance(to: .uploadFailed)
            return
        }
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        // Read the immutable snapshot taken at `startSetupCheck`, never the
        // mutable input fields, so the active upload target can't be swapped
        // after capture started. Fall back to the inputs only if (impossibly) no
        // snapshot exists.
        let creds = activeCredentials ?? (token: tokenInput, jobID: jobIDInput)
        let request = UploadRequest(
            url: AppConfig.captureSessionURL(jobID: creds.jobID),
            token: creds.token,
            bodyFileURL: bodyFileURL,
            boundary: encoder.boundary,
            sessionID: sessionID
        )

        let result = await uploader.upload(request)
        switch result {
        case .success:
            shareURL = AppConfig.backendURL
                .appendingPathComponent("jobs")
                .appendingPathComponent(creds.jobID).absoluteString
            _ = state.advance(to: .uploadComplete)
        case .failure(.unauthorized):
            errorMessage = "Your capture link has expired. Request a new one from the web app."
            _ = state.advance(to: .uploadFailed)
        case .failure:
            errorMessage = "Upload failed. Retry, or save the bundle locally."
            _ = state.advance(to: .uploadFailed)
        }
    }

    func buildManifest(mesh: MeshExportResult) -> CaptureSessionManifest {
        CaptureSessionManifest(
            sessionID: sessionID,
            jobID: activeCredentials?.jobID ?? jobIDInput,
            startedAt: CaptureSessionManifest.iso8601.string(from: startedAt),
            endedAt: CaptureSessionManifest.iso8601.string(from: Date()),
            deviceInfo: Self.currentDeviceInfo(),
            gpsOrigin: (originFix ?? location.latestFix)?.gpsOrigin
                ?? GPSOrigin(latitude: 0, longitude: 0, altitudeM: 0,
                             horizontalAccuracyM: 9999, verticalAccuracyM: 9999,
                             timestamp: CaptureSessionManifest.iso8601.string(from: startedAt)),
            captures: captures,
            worldMesh: WorldMesh(vertexCount: mesh.vertexCount, faceCount: mesh.faceCount)
        )
    }

    private func buildParts(manifest: CaptureSessionManifest, mesh: MeshExportResult) throws -> [MultipartPart] {
        var parts: [MultipartPart] = []
        let sessionJSON = try CaptureSessionManifest.encoder.encode(manifest)
        parts.append(MultipartPart(name: "session_json", filename: "session.json",
                                   contentType: "application/json", data: sessionJSON))
        for (i, data) in photoData.enumerated() {
            parts.append(MultipartPart(name: String(format: "photo_%02d", i),
                                       filename: String(format: "photo_%02d.jpg", i),
                                       contentType: "image/jpeg", data: data))
        }
        for (i, data) in depthData.enumerated() {
            parts.append(MultipartPart(name: String(format: "depth_%02d", i),
                                       filename: String(format: "depth_%02d.png", i),
                                       contentType: "image/png", data: data))
        }
        let meshData = try Data(contentsOf: mesh.fileURL)
        parts.append(MultipartPart(name: "world_mesh", filename: "arkit_mesh.obj",
                                   contentType: "model/obj", data: meshData))
        return parts
    }

    static func currentDeviceInfo() -> DeviceInfo {
        #if canImport(UIKit)
        let device = UIDevice.current
        return DeviceInfo(
            model: device.model,
            modelIdentifier: Self.modelIdentifier(),
            osVersion: device.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        )
        #else
        return DeviceInfo(model: "Unknown", modelIdentifier: "Unknown",
                          osVersion: "0", appVersion: "1.0.0")
        #endif
    }

    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            id += String(UnicodeScalar(UInt8(value)))
        }
    }
}
