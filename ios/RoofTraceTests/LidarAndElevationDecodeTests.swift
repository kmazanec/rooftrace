import XCTest
@testable import RoofTrace

final class LidarAndElevationDecodeTests: XCTestCase {
    func testDecodesLidarPointsResponse() throws {
        let json = """
        {
          "points": [[-89.65, 39.79, 1082.5], [-89.64, 39.80, 1083.1]],
          "point_count": 5213,
          "returned_count": 2,
          "bounds": [-89.65, 39.79, -89.64, 39.80]
        }
        """
        let decoded = try JSONDecoder.roofTraceAPI.decode(LidarPoints.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.pointCount, 5213)
        XCTAssertEqual(decoded.returnedCount, 2)
        XCTAssertTrue(decoded.hasPoints)
    }

    func testDecodesEmptyUnavailableLidarResponse() throws {
        let json = """
        { "points": [], "point_count": 0, "returned_count": 0, "bounds": null, "reason": "lidar_unavailable" }
        """
        let decoded = try JSONDecoder.roofTraceAPI.decode(LidarPoints.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.hasPoints)
        XCTAssertEqual(decoded.reason, "lidar_unavailable")
    }

    func testLidarDropsMalformedPoints() throws {
        let json = """
        { "points": [[-89.65, 39.79, 1082.5], [-89.64, 39.80], [1, 2, 3, 4]] }
        """
        let decoded = try JSONDecoder.roofTraceAPI.decode(LidarPoints.self, from: Data(json.utf8))
        // Two-element point dropped; four-element kept (>=3 floats parse fine).
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertTrue(decoded.points.allSatisfy { $0.count >= 3 })
    }

    func testFacetDecodesOptionalElevationThirdElement() throws {
        let json = """
        {
          "facet_id": "F1",
          "vertices": [[38.8977, -77.0365, 12.5], [38.8978, -77.0364], [38.8979, -77.0366, 12.8]]
        }
        """
        let facet = try JSONDecoder.roofTraceAPI.decode(RoofExport.Facet.self, from: Data(json.utf8))
        XCTAssertTrue(facet.hasElevation)
        // Horizontal coordinates resolve for all three (the ≥2 fix).
        XCTAssertEqual(facet.coordinates.count, 3)
        let v3d = facet.vertices3D
        XCTAssertEqual(v3d.count, 3)
        XCTAssertEqual(v3d[0].elevationM, 12.5)
        XCTAssertNil(v3d[1].elevationM)
        XCTAssertEqual(v3d[2].elevationM, 12.8)
    }

    func testFacetWithNoElevationReportsFlat() throws {
        let json = """
        { "facet_id": "F1", "vertices": [[38.0, -77.0], [38.0, -77.1]] }
        """
        let facet = try JSONDecoder.roofTraceAPI.decode(RoofExport.Facet.self, from: Data(json.utf8))
        XCTAssertFalse(facet.hasElevation)
        XCTAssertTrue(facet.vertices3D.allSatisfy { $0.elevationM == nil })
    }

    func testArtifactsDecodeLidarPointsURL() throws {
        let json = """
        {
          "schema_version": "1.2.0",
          "job": { "id": "job-1", "status": "ready" },
          "measurement": { "facets": [], "features": [], "warnings": [] },
          "provenance": null,
          "artifacts": {
            "pdf_url": null,
            "share_url": null,
            "lidar_points_url": "https://x/api/v1/jobs/job-1/lidar_points",
            "model_3d_url": null
          }
        }
        """
        let export = try JSONDecoder.roofTraceAPI.decode(RoofExport.self, from: Data(json.utf8))
        XCTAssertEqual(export.artifacts.lidarPointsURL?.absoluteString, "https://x/api/v1/jobs/job-1/lidar_points")
    }
}
