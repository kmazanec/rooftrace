import XCTest
@testable import RoofTrace

/// Phase 2.10 — multipart body assembly. 18 parts: session_json + 8 photos +
/// 8 depths + world_mesh. Verifies part names, Content-Types, and that the
/// session_json part re-parses to a valid manifest.
final class MultipartEncoderTests: XCTestCase {

    func makeParts() throws -> (parts: [MultipartPart], manifest: CaptureSessionManifest) {
        let manifest = ManifestSerializationTests.makeManifest()
        let sessionJSON = try CaptureSessionManifest.encoder.encode(manifest)
        var parts: [MultipartPart] = []
        parts.append(MultipartPart(name: "session_json", filename: "session.json",
                                   contentType: "application/json", data: sessionJSON))
        for i in 0..<8 {
            parts.append(MultipartPart(name: String(format: "photo_%02d", i),
                                       filename: String(format: "photo_%02d.jpg", i),
                                       contentType: "image/jpeg",
                                       data: Data([0xFF, 0xD8, 0xFF, UInt8(i)])))
        }
        for i in 0..<8 {
            parts.append(MultipartPart(name: String(format: "depth_%02d", i),
                                       filename: String(format: "depth_%02d.png", i),
                                       contentType: "image/png",
                                       data: Data([0x89, 0x50, 0x4E, UInt8(i)])))
        }
        parts.append(MultipartPart(name: "world_mesh", filename: "arkit_mesh.obj",
                                   contentType: "model/obj", data: Data("v 0 0 0\n".utf8)))
        return (parts, manifest)
    }

    func testEighteenParts() throws {
        let (parts, _) = try makeParts()
        XCTAssertEqual(parts.count, 18)
    }

    func testPartNamesAndContentTypes() throws {
        let (parts, _) = try makeParts()
        XCTAssertEqual(parts[0].name, "session_json")
        XCTAssertEqual(parts[0].contentType, "application/json")
        for i in 0..<8 {
            XCTAssertEqual(parts[1 + i].name, String(format: "photo_%02d", i))
            XCTAssertEqual(parts[1 + i].contentType, "image/jpeg")
        }
        for i in 0..<8 {
            XCTAssertEqual(parts[9 + i].name, String(format: "depth_%02d", i))
            XCTAssertEqual(parts[9 + i].contentType, "image/png")
        }
        XCTAssertEqual(parts[17].name, "world_mesh")
        XCTAssertEqual(parts[17].contentType, "model/obj")
    }

    func testEncodedBodyContainsAllDispositions() throws {
        let (parts, _) = try makeParts()
        let boundary = "----RoofTraceBoundaryTEST"
        let encoder = MultipartEncoder(boundary: boundary)
        let body = encoder.encode(parts)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"session_json\""))
        XCTAssertTrue(text.contains("filename=\"session.json\""))
        XCTAssertTrue(text.contains("name=\"photo_00\""))
        XCTAssertTrue(text.contains("name=\"depth_07\""))
        XCTAssertTrue(text.contains("name=\"world_mesh\""))
        XCTAssertTrue(text.contains("Content-Type: model/obj"))
        // Exactly 18 boundary delimiters + 1 closing delimiter.
        let opens = text.components(separatedBy: "--\(boundary)\r\n").count - 1
        XCTAssertEqual(opens, 18)
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
    }

    /// The streaming temp-file encoder (the production upload path) must produce
    /// output byte-identical to the in-memory encoder. This both exercises the
    /// streaming path and guards against the two encoders silently drifting.
    func testEncodeToTempFileMatchesInMemory() throws {
        let (parts, _) = try makeParts()
        let boundary = "----RoofTraceBoundaryTEST"
        let encoder = MultipartEncoder(boundary: boundary)

        let inMemory = encoder.encode(parts)

        let url = try encoder.encodeToTempFile(parts)
        defer { try? FileManager.default.removeItem(at: url) }
        let streamed = try Data(contentsOf: url)

        XCTAssertEqual(streamed, inMemory)
    }

    /// The session_json part bytes re-parse to a valid manifest (no corruption
    /// during multipart assembly).
    func testSessionJSONPartReparses() throws {
        let (parts, original) = try makeParts()
        let sessionPart = try XCTUnwrap(parts.first { $0.name == "session_json" })
        let decoded = try CaptureSessionManifest.decoder.decode(
            CaptureSessionManifest.self, from: sessionPart.data)
        XCTAssertEqual(decoded.manifestVersion, "1.0.0")
        XCTAssertEqual(decoded.captures.count, 8)
        XCTAssertEqual(decoded, original)
    }
}
