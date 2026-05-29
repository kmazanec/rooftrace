import Foundation
import simd

/// Serializes ARKit `simd` matrices to the ROW-major flat `[Double]` arrays the
/// session.json contract requires.
///
/// CRITICAL: ARKit's `simd_float4x4` / `simd_float3x3` are COLUMN-major —
/// `m.columns.0..3` are column vectors and `m[c]` indexes a COLUMN. Naively
/// flattening the columns (or `Array`-ing the matrix) emits column-major order,
/// which silently corrupts the extrinsic on the wire. This serializer builds row
/// `i` explicitly as `[columns[0][i], columns[1][i], columns[2][i], columns[3][i]]`.
enum MatrixSerializer {
    /// Row-major flattening of a 4x4. `m.columns.k[i]` is element (row i, col k).
    static func rowMajor(_ m: simd_float4x4) -> [Double] {
        let c = m.columns
        var out: [Double] = []
        out.reserveCapacity(16)
        for i in 0..<4 {
            out.append(Double(c.0[i]))
            out.append(Double(c.1[i]))
            out.append(Double(c.2[i]))
            out.append(Double(c.3[i]))
        }
        return out
    }

    /// Row-major flattening of a 3x3 (camera intrinsics).
    static func rowMajor(_ m: simd_float3x3) -> [Double] {
        let c = m.columns
        var out: [Double] = []
        out.reserveCapacity(9)
        for i in 0..<3 {
            out.append(Double(c.0[i]))
            out.append(Double(c.1[i]))
            out.append(Double(c.2[i]))
        }
        return out
    }
}
