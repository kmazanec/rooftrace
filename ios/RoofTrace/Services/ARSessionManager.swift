import Foundation
import simd
#if canImport(ARKit)
import ARKit
import UIKit
import CoreImage
import CoreVideo
#endif

/// The raw sensor outputs captured at one prompt tap.
struct CaptureFrame {
    let jpeg: Data
    /// Depth in meters as a flat row-major array, plus dimensions (for the encoder).
    let depthMeters: [Float]
    let depthWidth: Int
    let depthHeight: Int
    let worldToCamera: simd_float4x4
    let intrinsics: simd_float3x3
    let attitude: simd_quatf
    /// Changed from `String` to the enum defined in CaptureSessionManifest.swift
    /// (Models agent). Dependency: requires `AttitudeReferenceFrame` to be
    /// visible in this module before this file compiles.
    let attitudeReferenceFrame: AttitudeReferenceFrame
}

enum ARSessionError: Error {
    case noFrame
    case noDepth
    case lidarUnsupported
}

enum MeshExportError: Error {
    case emptyMesh
    case oversized
    case exportFailed
}

/// The injectable boundary the view model talks to. The concrete ARKit
/// implementation is device-only; tests inject a fake conforming to this.
///
/// `CaptureSensing` is left unannotated with `@MainActor` — the concrete class
/// is annotated instead, which is sufficient since it is always used through the
/// @MainActor view model. A fake in tests can conform without inheriting the
/// actor constraint.
protocol CaptureSensing: AnyObject {
    /// True iff the device provides ARKit `sceneDepth` (LiDAR Pro models).
    var supportsSceneDepth: Bool { get }
    func startSession()
    func stopSession()
    /// Probes for depth availability within a short window (setup check).
    func probeSceneDepth(timeout: TimeInterval) async -> Bool
    /// Captures the current frame's photo + depth + pose + attitude.
    func captureFrame() throws -> CaptureFrame
    /// Exports the accumulated world mesh to a temp OBJ file.
    func exportWorldMesh() async -> Result<MeshExportResult, MeshExportError>
}

/// Result of a world-mesh export.
struct MeshExportResult {
    let fileURL: URL
    let vertexCount: Int
    let faceCount: Int
}

#if canImport(ARKit)
/// Concrete ARKit implementation. Runs only on a LiDAR-equipped device; the
/// simulator and CI never instantiate this (the view model holds the protocol).
///
/// @MainActor: always created and used from the @MainActor view model. ARKit
/// delivers session delegate callbacks on the main thread, so this annotation
/// makes that assumption compiler-enforced and closes the data-race on
/// `meshAnchors` without an actor rewrite.
@MainActor
final class ARKitSessionManager: NSObject, CaptureSensing, ARSessionDelegate {
    private let session = ARSession()
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private let meshExporter = MeshExporter()

    var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func startSession() {
        guard supportsSceneDepth else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics = .sceneDepth
        config.worldAlignment = .gravity
        session.delegate = self
        session.run(config)
    }

    func stopSession() {
        session.pause()
    }

    func probeSceneDepth(timeout: TimeInterval) async -> Bool {
        guard supportsSceneDepth else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.currentFrame?.sceneDepth != nil { return true }
            // Honor task cancellation: bail out rather than sleeping past cancel.
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return session.currentFrame?.sceneDepth != nil
    }

    func captureFrame() throws -> CaptureFrame {
        guard let frame = session.currentFrame else { throw ARSessionError.noFrame }
        guard let depth = frame.sceneDepth else { throw ARSessionError.noDepth }

        let jpeg = try Self.jpeg(from: frame.capturedImage)
        let (depthMeters, w, h) = Self.depthArray(from: depth.depthMap)

        // ARKit `viewMatrix` is world->camera. Orientation .portrait matches the
        // capture UI; intrinsics come from the camera.
        let worldToCamera = frame.camera.viewMatrix(for: .portrait)
        let intrinsics = frame.camera.intrinsics
        let attitude = simd_quatf(frame.camera.transform)

        return CaptureFrame(
            jpeg: jpeg,
            depthMeters: depthMeters, depthWidth: w, depthHeight: h,
            worldToCamera: worldToCamera, intrinsics: intrinsics,
            attitude: attitude, attitudeReferenceFrame: .xArbitraryZVertical
        )
    }

    func exportWorldMesh() async -> Result<MeshExportResult, MeshExportError> {
        await meshExporter.export(anchors: Array(meshAnchors.values))
    }

    // MARK: ARSessionDelegate — accumulate mesh anchors

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        upsertMeshAnchors(anchors)
    }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        upsertMeshAnchors(anchors)
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors.removeValue(forKey: mesh.identifier) }
    }

    // MARK: - Private helpers

    /// Inserts or replaces every ARMeshAnchor in `anchors` by UUID. Shared by
    /// `didAdd` and `didUpdate` — the logic is identical.
    private func upsertMeshAnchors(_ anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
    }

    private static func jpeg(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else {
            throw ARSessionError.noFrame
        }
        let ui = UIImage(cgImage: cg)
        guard let data = ui.jpegData(compressionQuality: 0.9) else {
            throw ARSessionError.noFrame
        }
        return data
    }

    private static func depthArray(from depthMap: CVPixelBuffer) -> ([Float], Int, Int) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        var out = [Float](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(depthMap) {
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        }
        return (out, w, h)
    }
}
#endif
