import XCTest
import simd
@testable import RoofTrace

/// Phase 2.3 — THE highest-risk test, written before any model code.
///
/// ARKit's `simd_float4x4` / `simd_float3x3` are COLUMN-major: `columns.0..3`
/// are column vectors, and `Array(matrix)` / flattening the columns yields
/// column-major order. The session.json contract requires ROW-major arrays.
/// MatrixSerializer MUST build row `i` as
///   [columns[0][i], columns[1][i], columns[2][i], columns[3][i]].
/// These tests catch the silent column-major corruption bug.
final class MatrixSerializerTests: XCTestCase {

    func testIdentity4x4SerializesRowMajorIdentity() {
        let m = matrix_identity_float4x4
        let row = MatrixSerializer.rowMajor(m)
        XCTAssertEqual(row, [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ])
    }

    func testIdentity3x3SerializesRowMajorIdentity() {
        let m = matrix_identity_float3x3
        let row = MatrixSerializer.rowMajor(m)
        XCTAssertEqual(row, [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1
        ])
    }

    /// A 4x4 world->camera with a pure translation (13, 1.6, 4). In a row-major
    /// 4x4 the translation lives in the LAST COLUMN: indices 3, 7, 11. This is
    /// exactly capture 0 of the synthetic fixture. If the serializer emitted
    /// column-major, the translation would wrongly land in indices 12,13,14.
    func testTranslationLandsInLastColumnRowMajor() {
        // simd_float4x4(columns:) takes COLUMN vectors. The 4th column is the
        // translation; the upper-left 3x3 is identity (rotation).
        let m = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),   // column 0
            SIMD4<Float>(0, 1, 0, 0),   // column 1
            SIMD4<Float>(0, 0, 1, 0),   // column 2
            SIMD4<Float>(13, 1.6, 4, 1) // column 3 = translation
        ))
        let row = MatrixSerializer.rowMajor(m)
        // Float 1.6 widens to Double as 1.6000000238..., so compare with accuracy.
        let expected: [Double] = [
            1, 0, 0, 13,
            0, 1, 0, 1.6,
            0, 0, 1, 4,
            0, 0, 0, 1
        ]
        XCTAssertEqual(row.count, expected.count)
        for (a, b) in zip(row, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
        // Translation in the last column (row-major indices 3,7,11), NOT the
        // last row (column-major indices 12,13,14).
        XCTAssertEqual(row[3], 13)
        XCTAssertEqual(row[7], 1.6, accuracy: 1e-6)
        XCTAssertEqual(row[11], 4)
        XCTAssertEqual(row[12], 0)
        XCTAssertEqual(row[13], 0)
        XCTAssertEqual(row[14], 0)
    }

    /// A fully asymmetric matrix so every off-diagonal position is distinct.
    /// We construct it by COLUMNS (ARKit's convention) and assert the row-major
    /// output is the transpose. element[row][col] = row*10 + col.
    func testAsymmetricMatrixIsTransposedToRowMajor() {
        // We want element(r,c) = r*10 + c. simd_float4x4(columns:) wants column
        // vectors, so column c = [element(0,c), element(1,c), element(2,c), element(3,c)].
        func col(_ c: Int) -> SIMD4<Float> {
            SIMD4<Float>(Float(0 * 10 + c), Float(1 * 10 + c), Float(2 * 10 + c), Float(3 * 10 + c))
        }
        let m = simd_float4x4(columns: (col(0), col(1), col(2), col(3)))
        let row = MatrixSerializer.rowMajor(m)
        // Row-major: element(0,0), element(0,1), ... = 0,1,2,3, 10,11,12,13, ...
        XCTAssertEqual(row, [
            0, 1, 2, 3,
            10, 11, 12, 13,
            20, 21, 22, 23,
            30, 31, 32, 33
        ])
    }

    /// Same asymmetry check for the 3x3 intrinsics path.
    func testAsymmetric3x3IsTransposedToRowMajor() {
        func col(_ c: Int) -> SIMD3<Float> {
            SIMD3<Float>(Float(0 * 10 + c), Float(1 * 10 + c), Float(2 * 10 + c))
        }
        let m = simd_float3x3(columns: (col(0), col(1), col(2)))
        let row = MatrixSerializer.rowMajor(m)
        XCTAssertEqual(row, [
            0, 1, 2,
            10, 11, 12,
            20, 21, 22
        ])
    }
}
