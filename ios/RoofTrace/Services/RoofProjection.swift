import CoreLocation
import Foundation

/// Pure geometry that turns the report's WGS84 roof data into a local metric
/// scene for the SceneKit viewer — the native counterpart of the web viewer's
/// ENU projection + shared ground baseline (ADR-013). No SceneKit types here so
/// the math is unit-testable in isolation.
///
/// Frame: a local East-North-Up tangent plane centred on `origin`. X = metres
/// east, Y = metres up (elevation above the shared ground baseline), Z = metres
/// NORTH-negated (SceneKit is right-handed with -Z into the screen, so north maps
/// to -Z to keep a conventional top-down orientation). Elevations are expressed
/// relative to the single shared baseline so tilted facets and the point cloud
/// stay aligned (both come from the same LiDAR datum).
enum RoofProjection {
    static let feetPerMetre = 3.280839895

    /// A facet ready to render: its vertices in the local metric frame plus the
    /// fields the viewer colours/labels by.
    struct ProjectedFacet: Equatable, Sendable {
        let facetID: String
        let points: [SIMD3<Double>]
        let pitchRatio: Double?
        let hasElevation: Bool
    }

    struct Scene {
        let origin: CLLocationCoordinate2D
        let groundBaselineM: Double
        let facets: [ProjectedFacet]
        let points: [SIMD3<Double>]
        /// Half-extent (metres) of the populated geometry from the origin, used to
        /// frame the camera. Always positive.
        let radiusM: Double

        var isEmpty: Bool { facets.isEmpty && points.isEmpty }
    }

    /// Build a scene from report facets and an optional point cloud.
    /// `lidarPoints` are WGS84 [lon, lat, elev_ft] (the endpoint's wire shape).
    static func scene(
        facets: [RoofExport.Facet],
        lidarPoints: [[Double]] = []
    ) -> Scene {
        let facetVertices = facets.flatMap(\.vertices3D)
        let cloud = parseLidar(lidarPoints)

        let origin = referenceCoordinate(facetVertices: facetVertices, cloud: cloud)
        let baseline = groundBaseline(facetVertices: facetVertices, cloud: cloud)

        let projectedFacets = facets.map { facet in
            ProjectedFacet(
                facetID: facet.facetID,
                points: facet.vertices3D.map { vertex in
                    project(
                        coordinate: vertex.coordinate,
                        elevationM: vertex.elevationM ?? baseline,
                        origin: origin,
                        baselineM: baseline
                    )
                },
                pitchRatio: facet.pitchRatio,
                hasElevation: facet.hasElevation
            )
        }

        let projectedPoints = cloud.map { point in
            project(
                coordinate: point.coordinate,
                elevationM: point.elevationM,
                origin: origin,
                baselineM: baseline
            )
        }

        let radius = boundingRadius(facets: projectedFacets, points: projectedPoints)

        return Scene(
            origin: origin,
            groundBaselineM: baseline,
            facets: projectedFacets,
            points: projectedPoints,
            radiusM: radius
        )
    }

    // MARK: - Internals (internal for testing)

    struct LidarPoint {
        let coordinate: CLLocationCoordinate2D
        let elevationM: Double
    }

    /// [lon, lat, elev_ft] → coordinate + elevation in METRES.
    static func parseLidar(_ raw: [[Double]]) -> [LidarPoint] {
        raw.compactMap { triple in
            guard triple.count >= 3 else { return nil }
            let lon = triple[0], lat = triple[1], elevFt = triple[2]
            guard lon.isFinite, lat.isFinite, elevFt.isFinite,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return LidarPoint(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                elevationM: elevFt / feetPerMetre
            )
        }
    }

    /// Centroid of every horizontal coordinate; falls back to (0,0) when empty.
    static func referenceCoordinate(
        facetVertices: [(coordinate: CLLocationCoordinate2D, elevationM: Double?)],
        cloud: [LidarPoint]
    ) -> CLLocationCoordinate2D {
        var lats: [Double] = facetVertices.map { $0.coordinate.latitude }
        var lons: [Double] = facetVertices.map { $0.coordinate.longitude }
        lats.append(contentsOf: cloud.map(\.coordinate.latitude))
        lons.append(contentsOf: cloud.map(\.coordinate.longitude))
        guard !lats.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        return CLLocationCoordinate2D(
            latitude: lats.reduce(0, +) / Double(lats.count),
            longitude: lons.reduce(0, +) / Double(lons.count)
        )
    }

    /// Lowest elevation across facet vertices AND cloud points (the shared datum
    /// so z=0 is true ground). 0 when nothing carries elevation.
    static func groundBaseline(
        facetVertices: [(coordinate: CLLocationCoordinate2D, elevationM: Double?)],
        cloud: [LidarPoint]
    ) -> Double {
        let elevations = facetVertices.compactMap(\.elevationM) + cloud.map(\.elevationM)
        return elevations.min() ?? 0
    }

    /// Equirectangular projection of a coordinate into local ENU metres. Accurate
    /// to sub-centimetre over a single roof's extent (tens of metres).
    static func project(
        coordinate: CLLocationCoordinate2D,
        elevationM: Double,
        origin: CLLocationCoordinate2D,
        baselineM: Double
    ) -> SIMD3<Double> {
        let metresPerDegLat = 111_320.0
        let metresPerDegLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let east = (coordinate.longitude - origin.longitude) * metresPerDegLon
        let north = (coordinate.latitude - origin.latitude) * metresPerDegLat
        let up = elevationM - baselineM
        // North → -Z (see frame note above).
        return SIMD3<Double>(east, up, -north)
    }

    static func boundingRadius(facets: [ProjectedFacet], points: [SIMD3<Double>]) -> Double {
        let all = facets.flatMap(\.points) + points
        let maxHorizontal = all.map { max(abs($0.x), abs($0.z)) }.max() ?? 1
        return max(maxHorizontal, 1)
    }
}
