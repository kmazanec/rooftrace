import Foundation
import CoreVideo
import Compression

/// Encodes an ARKit `sceneDepth` float32 depth map (meters) to a 16-bit
/// grayscale PNG of uint16 millimeters, per the session.json contract:
/// pixel `v` decodes to `v / 1000.0` meters; 0 = no depth, 65535 = 65.535 m.
///
/// The PNG is written by a small self-contained 16-bit-grayscale encoder
/// (IHDR + zlib-deflated IDAT + IEND). This avoids the cross-iOS-version
/// fragility of `CGBitmapContext` 16-bit grayscale (the planned fallback,
/// promoted to the primary path) and gives a byte-deterministic, fully
/// round-trippable output. zlib deflate/inflate uses the system `Compression`
/// framework with the `.zlib` algorithm (raw DEFLATE) wrapped in the 2-byte
/// zlib header + Adler-32 trailer that PNG requires.
enum DepthMapEncoder {
    static let depthScale: Float = 1000.0
    static let maxMillimeters: UInt16 = 65535

    enum EncoderError: Error {
        case unsupportedPixelFormat(OSType)
        case lockFailed
        case compressionFailed
        case malformedPNG
    }

    // MARK: - scalar conversion

    /// meters -> uint16 millimeters, clamped to [0, 65535]. NaN/negative -> 0.
    static func metersToMillimeters(_ meters: Float) -> UInt16 {
        guard meters.isFinite, meters > 0 else { return 0 }
        let mm = (meters * depthScale).rounded()
        if mm >= Float(maxMillimeters) { return maxMillimeters }
        return UInt16(mm)
    }

    /// [min, max] depth in meters present, clamped to [0.0, 65.535].
    static func depthRangeMeters(_ depthsMeters: [Float]) -> [Double] {
        let valid = depthsMeters.filter { $0.isFinite }
        guard !valid.isEmpty else { return [0.0, 0.0] }
        let clampedMax = Double(min(valid.max()!, Float(maxMillimeters) / depthScale))
        let minClamped = Double(max(valid.min()!, 0.0))
        return [max(0.0, minClamped), max(0.0, clampedMax)]
    }

    // MARK: - encode

    /// Encodes from a CVPixelBuffer of `kCVPixelFormatType_DepthFloat32`.
    static func encodePNG(pixelBuffer: CVPixelBuffer) throws -> Data {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_DepthFloat32 else {
            throw EncoderError.unsupportedPixelFormat(format)
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw EncoderError.lockFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw EncoderError.lockFailed
        }

        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                samples[y * width + x] = metersToMillimeters(row[x])
            }
        }
        return try encodePNG16(samples: samples, width: width, height: height)
    }

    /// Encodes from a flat `[Float]` of depths in meters (row-major).
    static func encodePNG(depthsMeters: [Float], width: Int, height: Int) throws -> Data {
        precondition(depthsMeters.count == width * height)
        let samples = depthsMeters.map(metersToMillimeters)
        return try encodePNG16(samples: samples, width: width, height: height)
    }

    // MARK: - 16-bit grayscale PNG codec

    static func encodePNG16(samples: [UInt16], width: Int, height: Int) throws -> Data {
        precondition(samples.count == width * height)

        // Raw image data: each scanline prefixed with filter byte 0 (None),
        // samples big-endian uint16.
        var raw = Data()
        raw.reserveCapacity(height * (1 + width * 2))
        for y in 0..<height {
            raw.append(0) // filter: None
            for x in 0..<width {
                let v = samples[y * width + x]
                raw.append(UInt8(v >> 8))
                raw.append(UInt8(v & 0xFF))
            }
        }

        let idatPayload = try zlibCompress(raw)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG signature

        // IHDR
        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(width))
        ihdr.appendBigEndian(UInt32(height))
        ihdr.append(16)   // bit depth
        ihdr.append(0)    // color type: grayscale
        ihdr.append(0)    // compression: deflate
        ihdr.append(0)    // filter: adaptive
        ihdr.append(0)    // interlace: none
        png.appendChunk(type: "IHDR", payload: ihdr)
        png.appendChunk(type: "IDAT", payload: idatPayload)
        png.appendChunk(type: "IEND", payload: Data())
        return png
    }

    struct DecodedDepth {
        let width: Int
        let height: Int
        let pixels: [UInt16]
    }

    /// Minimal decoder for the grayscale-16 PNGs this encoder produces (filter 0,
    /// no interlace). Sufficient for round-trip tests and fixture verification.
    static func decodePNG16(_ data: Data) throws -> DecodedDepth {
        let bytes = [UInt8](data)
        guard bytes.count > 8,
              Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            throw EncoderError.malformedPNG
        }
        var i = 8
        var width = 0, height = 0
        var idat = Data()
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3])
            let type = String(bytes: bytes[(i+4)..<(i+8)], encoding: .ascii) ?? ""
            let payloadStart = i + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd + 4 <= bytes.count else { throw EncoderError.malformedPNG }
            let payload = Array(bytes[payloadStart..<payloadEnd])
            switch type {
            case "IHDR":
                width = Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
                height = Int(payload[4]) << 24 | Int(payload[5]) << 16 | Int(payload[6]) << 8 | Int(payload[7])
            case "IDAT":
                idat.append(contentsOf: payload)
            case "IEND":
                i = bytes.count
                continue
            default:
                break
            }
            i = payloadEnd + 4 // skip CRC
        }
        guard width > 0, height > 0 else { throw EncoderError.malformedPNG }

        let raw = try zlibDecompress(idat, expectedSize: height * (1 + width * 2))
        var pixels = [UInt16](repeating: 0, count: width * height)
        let rowStride = 1 + width * 2
        let rawBytes = [UInt8](raw)
        for y in 0..<height {
            let base = y * rowStride
            // filter byte at base assumed 0 (None) — what we wrote.
            for x in 0..<width {
                let hi = rawBytes[base + 1 + x * 2]
                let lo = rawBytes[base + 1 + x * 2 + 1]
                pixels[y * width + x] = UInt16(hi) << 8 | UInt16(lo)
            }
        }
        return DecodedDepth(width: width, height: height, pixels: pixels)
    }

    // MARK: - zlib (DEFLATE + zlib wrapper) via Compression framework

    /// Wraps raw DEFLATE in a zlib stream: 2-byte header + DEFLATE + Adler-32.
    static func zlibCompress(_ input: Data) throws -> Data {
        let deflated = try rawDeflate(input)
        var out = Data([0x78, 0x01]) // CMF/FLG: 32K window, no dict, fastest
        out.append(deflated)
        out.appendBigEndian(adler32(input))
        return out
    }

    static func zlibDecompress(_ input: Data, expectedSize: Int) throws -> Data {
        // Strip 2-byte zlib header and 4-byte Adler-32 trailer -> raw DEFLATE.
        guard input.count > 6 else { throw EncoderError.malformedPNG }
        let raw = input.subdata(in: (input.startIndex + 2)..<(input.endIndex - 4))
        return try rawInflate(raw, expectedSize: expectedSize)
    }

    private static func rawDeflate(_ input: Data) throws -> Data {
        try perform(input, operation: COMPRESSION_STREAM_ENCODE, hint: input.count)
    }

    private static func rawInflate(_ input: Data, expectedSize: Int) throws -> Data {
        try perform(input, operation: COMPRESSION_STREAM_DECODE, hint: expectedSize)
    }

    private static func perform(_ input: Data, operation: compression_stream_operation, hint: Int) throws -> Data {
        // compression_stream has no Swift no-arg init; allocate it via a pointer
        // and let compression_stream_init populate every field.
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw EncoderError.compressionFailed
        }
        defer { compression_stream_destroy(streamPtr) }

        let dstCapacity = max(64, hint + hint / 2 + 64)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        var output = Data()
        let result: Data? = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            streamPtr.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            streamPtr.pointee.src_size = input.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            repeat {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = dstCapacity
                let status = compression_stream_process(streamPtr, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstCapacity - streamPtr.pointee.dst_size
                    output.append(dst, count: produced)
                    if status == COMPRESSION_STATUS_END { return output }
                default:
                    return nil
                }
            } while true
        }
        guard let result else { throw EncoderError.compressionFailed }
        return result
    }

    /// Adler-32 checksum (zlib trailer).
    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        let mod: UInt32 = 65521
        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }
}

// MARK: - PNG chunk helpers

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendChunk(type: String, payload: Data) {
        appendBigEndian(UInt32(payload.count))
        let typeBytes = Data(type.utf8)
        append(typeBytes)
        append(payload)
        var crcInput = typeBytes
        crcInput.append(payload)
        appendBigEndian(PNGCRC.crc32(crcInput))
    }
}

/// PNG CRC-32 (ISO 3309 / same polynomial as zlib crc32).
enum PNGCRC {
    private static let table: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}
