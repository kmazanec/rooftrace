import Foundation
import Observation
import simd
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Dependency seams

/// Uploads an assembled multipart bundle. `MultipartUploader` is the production
/// conformer; tests inject a fake to exercise the upload state transitions.
protocol BundleUploading: AnyObject {
    func upload(_ request: UploadRequest) async -> Result<Void, UploadError>
}

extension MultipartUploader: BundleUploading {}

/// Writes an assembled bundle to a `.zip` on disk (the local-save recovery path).
protocol BundleArchiving {
    func archive(parts: [MultipartPart], named name: String) throws -> URL
}

extension BundleArchiver: BundleArchiving {}

/// Source of "now" and fresh identifiers. Injected so session timestamps and the
/// session id can be made deterministic in tests.
protocol ClockProviding {
    func now() -> Date
    func makeID() -> String
}

struct SystemClock: ClockProviding {
    func now() -> Date { Date() }
    func makeID() -> String { UUID().uuidString }
}

/// Supplies the device metadata recorded in the manifest. Injected so the
/// manifest builder is testable off-device.
protocol DeviceInfoProviding {
    var deviceInfo: DeviceInfo { get }
}

/// Real device info, read from `UIDevice`/`utsname` on iOS; a stable stub
/// elsewhere (so the manifest builder still compiles + runs in unit tests).
struct SystemDeviceInfoProvider: DeviceInfoProviding {
    var deviceInfo: DeviceInfo {
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
            // `machine` is a C char tuple of Int8; stop at the NUL terminator.
            // Reinterpret the byte's bit pattern so a high-bit (negative Int8)
            // byte can't trap the way `UInt8(value)` would.
            guard let value = element.value as? Int8, value > 0 else { return }
            id.unicodeScalars.append(UnicodeScalar(UInt8(bitPattern: value)))
        }
    }
}

// MARK: - Manifest builder

/// Pure value-type builder for the session manifest. Kept separate from the view
/// model so it can be unit-tested directly without spinning up the whole capture
/// flow. Holds the optional-GPS logic (nil origin when no trustworthy fix).
struct ManifestBuilder {
    let sessionID: String
    let startedAt: Date
    let jobID: String
    let captures: [CaptureEntry]
    let originFix: LocationFix?
    let latestFix: LocationFix?
    let deviceInfo: DeviceInfo
    let clock: any ClockProviding
    let mesh: MeshExportResult

    func build() -> CaptureSessionManifest {
        CaptureSessionManifest(
            sessionID: sessionID,
            jobID: jobID,
            startedAt: CaptureSessionManifest.iso8601.string(from: startedAt),
            endedAt: CaptureSessionManifest.iso8601.string(from: clock.now()),
            deviceInfo: deviceInfo,
            // Optional: omitted from JSON when no trustworthy fix was obtained.
            // No Null Island (0,0,9999) sentinel.
            gpsOrigin: (originFix ?? latestFix)?.gpsOrigin,
            captures: captures,
            worldMesh: WorldMesh(vertexCount: mesh.vertexCount, faceCount: mesh.faceCount)
        )
    }
}

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
    private(set) var shareURL: String?
    private(set) var errorMessage: String?
    private(set) var gpsReady: Bool = false

    /// True while a single `capture()` is mid-flight. Read by the view to disable
    /// the shutter so a double-tap can't fire two captures.
    private(set) var captureInFlight = false

    /// True while `saveBundleLocally()` is mid-flight, so the view can disable the
    /// save control and a double-tap can't start two archive writes.
    private(set) var isSavingBundle = false

    /// The on-disk `.zip` produced by the local-save recovery path, ready for
    /// export via the document picker. Set when the user saves the bundle locally.
    private(set) var savedBundleURL: URL?

    /// Guards against a second upload being kicked off while one is in flight
    /// (e.g. a double-tap on the final capture, or Retry mashed twice).
    private var uploadInFlight = false

    /// Stable across upload retries — the session.json idempotency key. Assigned
    /// from the injected clock in `init` (so tests can make it deterministic).
    private(set) var sessionID: String
    private let startedAt: Date

    /// Immutable snapshot of the upload target (token + job id), taken when the
    /// capture flow leaves token entry. The uploader and manifest read THIS, not
    /// the mutable `tokenInput`/`jobIDInput`, so a deep link or UI edit arriving
    /// after capture has started can never redirect the finished bundle to a
    /// different job. Nil until `startSetupCheck` snapshots it.
    private var activeCredentials: (token: String, jobID: String)?

    // MARK: - collaborators
    private let sensors: CaptureSensing?
    private let location: LocationProviding
    private let uploader: any BundleUploading
    private let archiver: any BundleArchiving
    private let clock: any ClockProviding
    private let deviceInfoProvider: any DeviceInfoProviding

    // MARK: - structured task handles
    private var originTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    // Built bundle (set at session end).
    private var photoData: [Data] = []
    private var depthData: [Data] = []
    private var meshResult: MeshExportResult?
    private var originFix: LocationFix?

    init(sensors: CaptureSensing?,
         location: LocationProviding,
         uploader: any BundleUploading = MultipartUploader(),
         archiver: any BundleArchiving = BundleArchiver(),
         clock: any ClockProviding = SystemClock(),
         deviceInfoProvider: any DeviceInfoProviding = SystemDeviceInfoProvider()) {
        self.sensors = sensors
        self.location = location
        self.uploader = uploader
        self.archiver = archiver
        self.clock = clock
        self.deviceInfoProvider = deviceInfoProvider
        // Stored-property initializers can't reference `self.clock`, so seed the
        // session identity here, after the clock is assigned.
        self.sessionID = clock.makeID()
        self.startedAt = clock.now()
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
        // Idempotent: only run from the setup-check state, so a re-fired `.task`
        // (view-identity churn) can't start a second AR session / re-probe.
        guard state == .setupCheck else { return }
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
            // Kick off the origin GPS fix in the background; keep the handle so
            // it can be cancelled on disappear.
            originTask = Task { await acquireOrigin() }
        } else {
            _ = state.advance(to: .lidarUnsupported)
            errorMessage = "This app requires an iPhone Pro or iPad Pro with LiDAR."
        }
    }

    private func acquireOrigin() async {
        originFix = await location.acquireOriginFix(targetAccuracyM: 10.0, timeout: 30.0)
        gpsReady = (originFix?.horizontalAccuracyM ?? .greatestFiniteMagnitude) <= 10.0
    }

    /// Cancel any in-flight background work and stop the sensor session. The view
    /// may call this on disappear so a backgrounded capture doesn't keep the GPS
    /// fix or upload running.
    func cancelPendingWork() {
        originTask?.cancel()
        uploadTask?.cancel()
        sensors?.stopSession()
    }

    // MARK: - capture

    var currentPromptIndex: Int? {
        if case let .capturePrompt(i) = state { return i }
        return nil
    }

    var currentPrompt: PromptStep? {
        currentPromptIndex.flatMap { PromptLibrary.step(at: $0) }
    }

    /// Performs one capture at the current prompt and advances. Returns false on
    /// error. The CPU-heavy depth PNG encode runs off the main actor.
    @discardableResult
    func capture() async -> Bool {
        guard !captureInFlight else { return false }
        captureInFlight = true
        defer { captureInFlight = false }

        guard let index = currentPromptIndex, let sensors else { return false }
        guard let prompt = PromptLibrary.step(at: index) else { return false }
        do {
            // `captureFrame()` reads ARKit state — it's a @MainActor sensor call.
            let frame = try sensors.captureFrame()

            // The pixel work (PNG encode + range scan) is pure CPU over Sendable
            // [Float] arrays — push it off the main actor so the UI doesn't hitch.
            // Capture only the Sendable value-type fields, not the whole frame.
            let depthMeters = frame.depthMeters
            let depthWidth = frame.depthWidth
            let depthHeight = frame.depthHeight
            let depthPNG = try await Task.detached(priority: .userInitiated) {
                try DepthMapEncoder.encodePNG(
                    depthsMeters: depthMeters,
                    width: depthWidth,
                    height: depthHeight)
            }.value
            let depthRange = await Task.detached(priority: .userInitiated) {
                DepthMapEncoder.depthRangeMeters(depthMeters)
            }.value

            // Back on the main actor (after the awaits) — safe to mutate state.
            let entry = CaptureEntry(
                captureIndex: index,
                promptLabel: prompt.label,
                photoFilename: Self.photoFilename(index),
                depthFilename: Self.depthFilename(index),
                timestamp: CaptureSessionManifest.iso8601.string(from: clock.now()),
                // Optional: nil when no trustworthy fix — omitted from JSON, no
                // Null Island (0,0,9999) sentinel.
                gps: (location.latestFix ?? originFix)?.gpsFix,
                cameraPose: CameraPose(intrinsics: frame.intrinsics, worldToCamera: frame.worldToCamera),
                attitude: AttitudeQuaternion(quaternion: frame.attitude,
                                             referenceFrame: frame.attitudeReferenceFrame),
                depthRangeM: depthRange
            )
            captures.append(entry)
            photoData.append(frame.jpeg)
            depthData.append(depthPNG)

            if index == CaptureSessionState.promptCount - 1 {
                // Last prompt: transition to .uploading synchronously so a
                // double-tap can't append a 9th capture or fire a second upload
                // (the .capturePrompt(7) -> .uploading edge fires exactly once).
                guard state.advance(to: .uploading) else { return false }
                uploadTask = Task { await finishAndUpload() }
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
        guard !isSavingBundle else { return }
        isSavingBundle = true
        defer { isSavingBundle = false }

        guard state == .uploadFailed, let mesh = meshResult else { return }
        let manifest = buildManifest(mesh: mesh)
        do {
            let parts = try await buildParts(manifest: manifest, mesh: mesh)
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
            parts = try await buildParts(manifest: manifest, mesh: mesh)
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

    private func buildManifest(mesh: MeshExportResult) -> CaptureSessionManifest {
        ManifestBuilder(
            sessionID: sessionID,
            startedAt: startedAt,
            jobID: activeCredentials?.jobID ?? jobIDInput,
            captures: captures,
            originFix: originFix,
            latestFix: location.latestFix,
            deviceInfo: deviceInfoProvider.deviceInfo,
            clock: clock,
            mesh: mesh
        ).build()
    }

    private func buildParts(manifest: CaptureSessionManifest, mesh: MeshExportResult) async throws -> [MultipartPart] {
        var parts: [MultipartPart] = []
        let sessionJSON = try CaptureSessionManifest.encoder.encode(manifest)
        parts.append(MultipartPart(name: "session_json", filename: "session.json",
                                   contentType: "application/json", data: sessionJSON))
        for (i, data) in photoData.enumerated() {
            parts.append(MultipartPart(name: String(format: "photo_%02d", i),
                                       filename: Self.photoFilename(i),
                                       contentType: "image/jpeg", data: data))
        }
        for (i, data) in depthData.enumerated() {
            parts.append(MultipartPart(name: String(format: "depth_%02d", i),
                                       filename: Self.depthFilename(i),
                                       contentType: "image/png", data: data))
        }
        // The OBJ mesh can be 60-120MB; read it off the main actor so the load
        // doesn't block UI. `fileURL` is a Sendable value captured by copy.
        let meshFileURL = mesh.fileURL
        let meshData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: meshFileURL)
        }.value
        parts.append(MultipartPart(name: "world_mesh", filename: "arkit_mesh.obj",
                                   contentType: "model/obj", data: meshData))
        return parts
    }

    // MARK: - filename formatting

    private static func photoFilename(_ i: Int) -> String { String(format: "photo_%02d.jpg", i) }
    private static func depthFilename(_ i: Int) -> String { String(format: "depth_%02d.png", i) }
}
