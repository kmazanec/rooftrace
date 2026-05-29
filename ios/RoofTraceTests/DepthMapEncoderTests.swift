import XCTest
import CoreVideo
@testable import RoofTrace

/// Phase 2.8 — float32 meters -> uint16 millimeters -> 16-bit grayscale PNG.
/// Round-trips through a real PNG encode/decode and verifies exact pixel values.
final class DepthMapEncoderTests: XCTestCase {

    /// The core scalar conversion: meters -> clamped uint16 millimeters.
    func testMetersToMillimetersScalar() {
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(0.0), 0)
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(1.0), 1000)
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(2.5), 2500)
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(5.0), 5000)
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(70.0), 65535) // clamped
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(-1.0), 0)     // negative clamps to 0
        XCTAssertEqual(DepthMapEncoder.metersToMillimeters(.nan), 0)     // NaN -> 0 (no depth)
    }

    func testDepthRangeMeters() {
        let depths: [Float] = [0.0, 1.0, 2.5, 5.0, 70.0]
        let range = DepthMapEncoder.depthRangeMeters(depths)
        // min nonzero handling: contract clamps to [0, 65.535]; 70 clamps to 65.535.
        XCTAssertEqual(range[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(range[1], 65.535, accuracy: 1e-3)
    }

    /// Full encode -> decode round-trip on a 5-pixel-wide row.
    func testEncodeDecodeRoundTrip() throws {
        let depths: [Float] = [0.0, 1.0, 2.5, 5.0, 70.0]
        let png = try DepthMapEncoder.encodePNG(depthsMeters: depths, width: 5, height: 1)
        let decoded = try DepthMapEncoder.decodePNG16(png)
        XCTAssertEqual(decoded.width, 5)
        XCTAssertEqual(decoded.height, 1)
        XCTAssertEqual(decoded.pixels, [0, 1000, 2500, 5000, 65535])
    }

    /// Encoding from a real CVPixelBuffer (DepthFloat32) produces the same bytes.
    func testEncodeFromPixelBuffer() throws {
        let depths: [Float] = [0.0, 1.0, 2.5, 5.0, 70.0]
        let buffer = try Self.makeDepthBuffer(depths, width: 5, height: 1)
        let png = try DepthMapEncoder.encodePNG(pixelBuffer: buffer)
        let decoded = try DepthMapEncoder.decodePNG16(png)
        XCTAssertEqual(decoded.pixels, [0, 1000, 2500, 5000, 65535])
    }

    // MARK: - helpers

    static func makeDepthBuffer(_ depths: [Float], width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_DepthFloat32, attrs, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                row[x] = depths[y * width + x]
            }
        }
        return buffer
    }
}
