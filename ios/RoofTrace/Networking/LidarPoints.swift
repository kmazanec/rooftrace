import Foundation

/// Decimated LiDAR point cloud for the native 3D viewer, fetched from
/// /api/v1/jobs/:id/lidar_points (ADR-013). Points are WGS84 [lon, lat, elev_ft];
/// the endpoint never 5xxes — an unavailable cloud comes back as an empty list
/// with a `reason`.
struct LidarPoints: Decodable, Equatable, Sendable {
    let points: [[Double]]
    let pointCount: Int
    let returnedCount: Int
    let bounds: [Double]?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case points
        case pointCount
        case returnedCount
        case bounds
        case reason
    }

    init(
        points: [[Double]],
        pointCount: Int = 0,
        returnedCount: Int = 0,
        bounds: [Double]? = nil,
        reason: String? = nil
    ) {
        self.points = points
        self.pointCount = pointCount
        self.returnedCount = returnedCount
        self.bounds = bounds
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawPoints = try container.decodeIfPresent([LossyPoint].self, forKey: .points) ?? []
        points = rawPoints.map(\.values).filter { $0.count >= 3 }
        pointCount = try container.decodeIfPresent(Int.self, forKey: .pointCount) ?? 0
        returnedCount = try container.decodeIfPresent(Int.self, forKey: .returnedCount) ?? points.count
        bounds = try container.decodeIfPresent([Double].self, forKey: .bounds)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    /// True when the cloud has at least one usable point.
    var hasPoints: Bool { !points.isEmpty }
}

private struct LossyPoint: Decodable, Equatable, Sendable {
    let values: [Double]

    init(from decoder: Decoder) throws {
        values = (try? [Double](from: decoder))?.filter(\.isFinite) ?? []
    }
}
