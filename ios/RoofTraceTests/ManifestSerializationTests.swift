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

    // MARK: - Optional GPS wire behavior

    /// A manifest built with no GPS encodes without `"gps_origin"` and without
    /// per-capture `"gps"` keys (Swift omits nil Optionals from JSON), and decodes
    /// back to nil on both fields. This pins the no-GPS wire contract so a future
    /// schema change that makes the fields non-optional would fail loudly here.
    func testNoGPSManifestOmitsGPSKeysInJSON() throws {
        let manifest = ManifestFixtures.make(gpsOrigin: nil, perCaptureGPS: nil)
        let data = try CaptureSessionManifest.encoder.encode(manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("\"gps_origin\""),
                       "gps_origin must be absent when nil")
        XCTAssertFalse(json.contains("\"gps\""),
                       "per-capture gps must be absent when nil")

        let decoded = try CaptureSessionManifest.decoder.decode(CaptureSessionManifest.self, from: data)
        XCTAssertNil(decoded.gpsOrigin, "decoded gpsOrigin must be nil")
        XCTAssertNil(decoded.captures[0].gps, "decoded per-capture gps must be nil")
    }

    // MARK: - Fixtures

    /// Thin wrapper kept for backward-compat — MultipartEncoderTests calls this.
    /// Delegates to the shared `ManifestFixtures.make()` so there is one source
    /// of truth for the standard 8-capture fixture.
    static func makeManifest() -> CaptureSessionManifest {
        ManifestFixtures.make()
    }
}
