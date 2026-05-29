import XCTest
@testable import RoofTrace

/// Phase 2.4 — Codable round-trip + cross-validation against the committed
/// synthetic fixture session.json. The fixture is added to the test target's
/// bundle resources so it loads at runtime.
final class ManifestSerializationTests: XCTestCase {

    /// A hand-built manifest round-trips through JSONEncoder/JSONDecoder unchanged.
    func testCodableRoundTrip() throws {
        let manifest = Self.makeManifest()
        let data = try CaptureSessionManifest.encoder.encode(manifest)
        let decoded = try CaptureSessionManifest.decoder.decode(CaptureSessionManifest.self, from: data)
        XCTAssertEqual(decoded.manifestVersion, "1.0.0")
        XCTAssertEqual(decoded.captures.count, 8)
        XCTAssertEqual(decoded.captures[0].promptLabel, .frontLeftCorner)
        XCTAssertEqual(decoded.worldMesh.filename, "arkit_mesh.obj")
        XCTAssertEqual(decoded.worldMesh.coordinateFrame, "arkit_session_local")
        XCTAssertEqual(decoded.captures[0].depthScale, 1000.0)
        XCTAssertEqual(decoded.captures[0].depthUnit, "mm_as_uint16")
    }

    func testManifestVersionConstant() {
        let manifest = Self.makeManifest()
        XCTAssertEqual(manifest.manifestVersion, "1.0.0")
    }

    func testEightCaptures() {
        let manifest = Self.makeManifest()
        XCTAssertEqual(manifest.captures.count, 8)
        XCTAssertEqual(Set(manifest.captures.map(\.promptLabel)).count, 8)
    }

    /// Encoded JSON uses snake_case keys matching the schema (not Swift camelCase).
    func testEncodedKeysAreSnakeCase() throws {
        let manifest = Self.makeManifest()
        let data = try CaptureSessionManifest.encoder.encode(manifest)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"manifest_version\""))
        XCTAssertTrue(json.contains("\"world_to_camera_row_major\""))
        XCTAssertTrue(json.contains("\"intrinsics_row_major\""))
        XCTAssertTrue(json.contains("\"prompt_label\""))
        XCTAssertTrue(json.contains("\"horizontal_accuracy_m\""))
        XCTAssertTrue(json.contains("\"quaternion_w\""))
        XCTAssertFalse(json.contains("\"manifestVersion\""))
    }

    /// The committed synthetic fixture decodes cleanly through the Swift model —
    /// this cross-validates the fixture against the Swift encoder/contract.
    func testSyntheticFixtureDecodes() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "session", withExtension: "json"),
            "session.json must be bundled as a test resource (see project resources)."
        )
        let data = try Data(contentsOf: url)
        let manifest = try CaptureSessionManifest.decoder.decode(CaptureSessionManifest.self, from: data)
        XCTAssertEqual(manifest.manifestVersion, "1.0.0")
        XCTAssertEqual(manifest.captures.count, 8)
        XCTAssertEqual(manifest.captures.map(\.captureIndex), Array(0...7))
        XCTAssertEqual(manifest.worldMesh.format, "obj")
        XCTAssertEqual(manifest.worldMesh.coordinateFrame, "arkit_session_local")
        // Capture 0 is the identity-rotation translate; row-major translation in
        // indices 3,7,11.
        let pose = manifest.captures[0].cameraPose.worldToCameraRowMajor
        XCTAssertEqual(pose.count, 16)
        XCTAssertEqual(pose[3], 13.0, accuracy: 1e-9)
        XCTAssertEqual(pose[7], 1.6, accuracy: 1e-9)
        XCTAssertEqual(pose[11], 4.0, accuracy: 1e-9)
    }

    // MARK: - Fixtures

    static func makeManifest() -> CaptureSessionManifest {
        let labels = PromptLabel.allCases
        let captures = (0..<8).map { i in
            CaptureEntry(
                captureIndex: i,
                promptLabel: labels[i],
                photoFilename: String(format: "photo_%02d.jpg", i),
                depthFilename: String(format: "depth_%02d.png", i),
                timestamp: "2026-05-28T14:32:1\(i).000Z",
                gps: GPSFix(
                    latitude: 40.808, longitude: -96.706, altitudeM: 360.0,
                    horizontalAccuracyM: 4.0, verticalAccuracyM: 6.0
                ),
                cameraPose: CameraPose(
                    intrinsicsRowMajor: [80, 0, 50, 0, 80, 50, 0, 0, 1],
                    worldToCameraRowMajor: [1, 0, 0, 13, 0, 1, 0, 1.6, 0, 0, 1, 4, 0, 0, 0, 1]
                ),
                attitude: AttitudeQuaternion(
                    quaternionW: 1, quaternionX: 0, quaternionY: 0, quaternionZ: 0,
                    referenceFrame: "xArbitraryZVertical"
                ),
                depthRangeM: [2.0, 2.0]
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
            gpsOrigin: GPSOrigin(
                latitude: 40.808, longitude: -96.706, altitudeM: 360.0,
                horizontalAccuracyM: 3.5, verticalAccuracyM: 5.0,
                timestamp: "2026-05-28T14:32:00.000Z"
            ),
            captures: captures,
            worldMesh: WorldMesh(vertexCount: 8, faceCount: 4)
        )
    }
}
