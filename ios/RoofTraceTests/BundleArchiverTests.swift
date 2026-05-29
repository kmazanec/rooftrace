import XCTest
@testable import RoofTrace

/// The local-save recovery path: `BundleArchiver` writes the assembled capture
/// parts to a single `.zip` on disk (the artifact handed to the document picker
/// for export). Verifies a real, well-formed zip is produced.
final class BundleArchiverTests: XCTestCase {

    private func makeParts() -> [MultipartPart] {
        var parts: [MultipartPart] = []
        parts.append(MultipartPart(name: "session_json", filename: "session.json",
                                   contentType: "application/json",
                                   data: Data(#"{"manifest_version":"1.0.0"}"#.utf8)))
        parts.append(MultipartPart(name: "photo_00", filename: "photo_00.jpg",
                                   contentType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0x00])))
        parts.append(MultipartPart(name: "depth_00", filename: "depth_00.png",
                                   contentType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        parts.append(MultipartPart(name: "world_mesh", filename: "arkit_mesh.obj",
                                   contentType: "model/obj", data: Data("v 0 0 0\n".utf8)))
        return parts
    }

    func testArchiveProducesZipOnDisk() throws {
        let url = try BundleArchiver().archive(parts: makeParts(), named: "rooftrace-capture-test")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        // Zip local-file-header magic: "PK\x03\x04".
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
    }

    /// Two archive calls don't collide on a stale destination (the previous
    /// `.zip` of the same name is replaced, not appended to / errored on).
    func testArchiveIsRepeatable() throws {
        let archiver = BundleArchiver()
        let first = try archiver.archive(parts: makeParts(), named: "rooftrace-capture-test")
        defer { try? FileManager.default.removeItem(at: first) }
        let second = try archiver.archive(parts: makeParts(), named: "rooftrace-capture-test")
        defer { try? FileManager.default.removeItem(at: second) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertGreaterThan(try Data(contentsOf: second).count, 0)
    }
}
