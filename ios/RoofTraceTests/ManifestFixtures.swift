import Foundation
@testable import RoofTrace

/// Shared manifest-building helpers for the test suite. All parameterised so
/// tests can request edge-case manifests (no GPS, custom GPS, etc.) without
/// duplicating construction code.
enum ManifestFixtures {

    // MARK: - Stable defaults

    static let defaultGPSOrigin = GPSOrigin(
        latitude: 40.808, longitude: -96.706, altitudeM: 360.0,
        horizontalAccuracyM: 3.5, verticalAccuracyM: 5.0,
        timestamp: "2026-05-28T14:32:00.000Z"
    )

    static let defaultPerCaptureGPS = GPSFix(
        latitude: 40.808, longitude: -96.706, altitudeM: 360.0,
        horizontalAccuracyM: 4.0, verticalAccuracyM: 6.0
    )

    // MARK: - Factory

    /// Builds a synthetic 8-capture manifest with controllable GPS values.
    ///
    /// - Parameters:
    ///   - gpsOrigin: Passed as `CaptureSessionManifest.gpsOrigin`. Pass `nil`
    ///     to produce a manifest that omits the `gps_origin` key in JSON.
    ///   - perCaptureGPS: Passed as `CaptureEntry.gps` for every capture. Pass
    ///     `nil` to omit the `gps` key from all per-capture objects.
    static func make(
        gpsOrigin: GPSOrigin? = defaultGPSOrigin,
        perCaptureGPS: GPSFix? = defaultPerCaptureGPS
    ) -> CaptureSessionManifest {
        let labels = PromptLabel.allCases
        let captures = (0..<8).map { i in
            CaptureEntry(
                captureIndex: i,
                promptLabel: labels[i],
                photoFilename: String(format: "photo_%02d.jpg", i),
                depthFilename: String(format: "depth_%02d.png", i),
                timestamp: "2026-05-28T14:32:1\(i).000Z",
                gps: perCaptureGPS,
                cameraPose: CameraPose(
                    intrinsicsRowMajor: [80, 0, 50, 0, 80, 50, 0, 0, 1],
                    worldToCameraRowMajor: [1, 0, 0, 13, 0, 1, 0, 1.6, 0, 0, 1, 4, 0, 0, 0, 1]
                ),
                attitude: AttitudeQuaternion(
                    quaternionW: 1, quaternionX: 0, quaternionY: 0, quaternionZ: 0,
                    referenceFrame: .xArbitraryZVertical
                ),
                depthRangeM: [0.5, 5.0]
            )
        }
        return CaptureSessionManifest(
            sessionID: "5e551011-0000-4000-8000-000000000001",
            jobID: "10b00000-0000-4000-8000-000000000002",
            startedAt: "2026-05-28T14:32:00.000Z",
            endedAt: "2026-05-28T14:33:30.000Z",
            deviceInfo: DeviceInfo(
                model: "iPhone 15 Pro", modelIdentifier: "iPhone16,1",
                osVersion: "17.5.1", appVersion: "1.0.0"
            ),
            gpsOrigin: gpsOrigin,
            captures: captures,
            worldMesh: WorldMesh(vertexCount: 8, faceCount: 4)
        )
    }
}

// MARK: - Test clock

/// A `ClockProviding` conformer that returns a fixed date and a fixed ID.
/// Used by `ManifestBuilderTests` (and any future test that needs deterministic
/// timestamps) without any real-time dependency.
struct FixedClock: ClockProviding {
    let date: Date
    let id: String
    func now() -> Date { date }
    func makeID() -> String { id }
}
