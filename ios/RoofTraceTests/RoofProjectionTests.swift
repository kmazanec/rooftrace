import CoreLocation
import XCTest
@testable import RoofTrace

final class RoofProjectionTests: XCTestCase {
    private func facet(_ vertices: [[Double]], id: String = "F1", pitch: Double? = 6.0) throws -> RoofExport.Facet {
        // Build a Facet through the decoder so it exercises the real vertex path.
        var object: [String: Any] = ["facet_id": id, "vertices": vertices]
        if let pitch { object["pitch_ratio"] = pitch }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.roofTraceAPI.decode(RoofExport.Facet.self, from: data)
    }

    func testParseLidarConvertsFeetToMetresAndDropsBadPoints() {
        let parsed = RoofProjection.parseLidar([
            [-77.0, 38.0, 32.808399],   // ~10 m
            [-77.0, 38.0],              // too short → dropped
            [200.0, 38.0, 10.0],        // bad lon → dropped
            [-77.0, 38.0, .nan]         // non-finite → dropped
        ])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].elevationM, 10.0, accuracy: 1e-3)
    }

    func testGroundBaselineIsMinAcrossFacetsAndCloud() throws {
        let facets = [try facet([[38.0, -77.0, 15.0], [38.0, -77.001, 18.0]])]
        let cloud = RoofProjection.parseLidar([[-77.0, 38.0, 32.808399]]) // 10 m
        let vertices = facets.flatMap(\.vertices3D)
        let baseline = RoofProjection.groundBaseline(facetVertices: vertices, cloud: cloud)
        XCTAssertEqual(baseline, 10.0, accuracy: 1e-3)
    }

    func testProjectPlacesOriginAtZeroAndUpAboveBaseline() {
        let origin = CLLocationCoordinate2D(latitude: 38.0, longitude: -77.0)
        let p = RoofProjection.project(
            coordinate: origin,
            elevationM: 25.0,
            origin: origin,
            baselineM: 10.0
        )
        XCTAssertEqual(p.x, 0, accuracy: 1e-6)
        XCTAssertEqual(p.z, 0, accuracy: 1e-6)
        XCTAssertEqual(p.y, 15.0, accuracy: 1e-6) // 25 - 10
    }

    func testProjectEastAndNorthSignsAreCorrect() {
        let origin = CLLocationCoordinate2D(latitude: 38.0, longitude: -77.0)
        let east = RoofProjection.project(
            coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -76.999),
            elevationM: 0, origin: origin, baselineM: 0
        )
        let north = RoofProjection.project(
            coordinate: CLLocationCoordinate2D(latitude: 38.001, longitude: -77.0),
            elevationM: 0, origin: origin, baselineM: 0
        )
        XCTAssertGreaterThan(east.x, 0)       // east of origin → +X
        XCTAssertEqual(east.z, 0, accuracy: 1e-6)
        XCTAssertLessThan(north.z, 0)         // north of origin → -Z (frame note)
        XCTAssertEqual(north.x, 0, accuracy: 1e-6)
    }

    func testSceneBuildsTiltedFacetsWhenElevationPresent() throws {
        let facets = [try facet([
            [38.0, -77.0, 10.0],
            [38.0, -77.001, 12.0],
            [38.001, -77.001, 14.0]
        ])]
        let scene = RoofProjection.scene(facets: facets, lidarPoints: [])
        XCTAssertEqual(scene.facets.count, 1)
        XCTAssertTrue(scene.facets[0].hasElevation)
        // Vertices span a real height range (tilted), relative to the baseline (10).
        let ys = scene.facets[0].points.map(\.y)
        XCTAssertEqual(ys.min() ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(ys.max() ?? -1, 4.0, accuracy: 1e-6)
        XCTAssertGreaterThan(scene.radiusM, 0)
    }

    func testSceneIsFlatWhenNoElevation() throws {
        let facets = [try facet([[38.0, -77.0], [38.0, -77.001], [38.001, -77.001]])]
        let scene = RoofProjection.scene(facets: facets, lidarPoints: [])
        XCTAssertFalse(scene.facets[0].hasElevation)
        XCTAssertEqual(scene.groundBaselineM, 0)
        XCTAssertTrue(scene.facets[0].points.allSatisfy { abs($0.y) < 1e-9 })
    }

    func testSceneIncludesProjectedCloudWhenProvided() throws {
        let facets = [try facet([[38.0, -77.0, 10.0], [38.0, -77.001, 10.0], [38.001, -77.0, 10.0]])]
        let scene = RoofProjection.scene(
            facets: facets,
            lidarPoints: [[-77.0005, 38.0005, 39.3700788]] // ~12 m
        )
        XCTAssertEqual(scene.points.count, 1)
        XCTAssertEqual(scene.points[0].y, 2.0, accuracy: 1e-2) // 12 - 10 baseline
    }
}
