import XCTest
@testable import RoofTrace

/// Phase 7.1 — the committed synthetic fixture decodes through the Swift model
/// and every contract-frozen field is present and correct. This is the iOS half
/// of the cross-language field-drift guard: the Python side validates the same
/// session.json against shared/ios_session_schema.json in CI.
final class FixtureParseTests: XCTestCase {

    private func loadFixtureManifest() throws -> CaptureSessionManifest {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "session", withExtension: "json"),
            "synthetic_house/session.json must be bundled into the test target."
        )
        let data = try Data(contentsOf: url)
        return try CaptureSessionManifest.decoder.decode(CaptureSessionManifest.self, from: data)
    }

    func testFixtureDecodesAndMatchesContract() throws {
        let manifest = try loadFixtureManifest()
        XCTAssertEqual(manifest.manifestVersion, "1.0.0")
        XCTAssertEqual(manifest.captures.count, 8)

        // Every prompt_label is a valid enum case, in walk-around order.
        XCTAssertEqual(manifest.captures.map(\.promptLabel), PromptLabel.allCases)

        // World mesh consts.
        XCTAssertEqual(manifest.worldMesh.filename, "arkit_mesh.obj")
        XCTAssertEqual(manifest.worldMesh.format, "obj")
        XCTAssertEqual(manifest.worldMesh.coordinateFrame, "arkit_session_local")

        // Depth consts on every capture.
        for capture in manifest.captures {
            XCTAssertEqual(capture.depthScale, 1000.0)
            XCTAssertEqual(capture.depthUnit, "mm_as_uint16")
            XCTAssertEqual(capture.cameraPose.intrinsicsRowMajor.count, 9)
            XCTAssertEqual(capture.cameraPose.worldToCameraRowMajor.count, 16)
            XCTAssertEqual(capture.depthRangeM.count, 2)
        }

        // GPS origin altitude is the HAE value documented in the fixture README.
        XCTAssertEqual(try XCTUnwrap(manifest.gpsOrigin).altitudeM, 360.0, accuracy: 1e-6)
    }

    /// Re-encoding the decoded manifest and re-decoding is stable (no field loss).
    func testFixtureReencodeRoundTrips() throws {
        let manifest = try loadFixtureManifest()
        let data = try CaptureSessionManifest.encoder.encode(manifest)
        let again = try CaptureSessionManifest.decoder.decode(CaptureSessionManifest.self, from: data)
        XCTAssertEqual(manifest, again)
    }
}
