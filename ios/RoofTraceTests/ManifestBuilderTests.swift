import XCTest
@testable import RoofTrace

/// Unit tests for `ManifestBuilder` — the pure value-type that assembles the
/// `CaptureSessionManifest`. Tests inject a `FixedClock` (defined in
/// `ManifestFixtures.swift`) so timestamps and session IDs are deterministic.
final class ManifestBuilderTests: XCTestCase {

    // MARK: - Helpers

    /// A stable fake `MeshExportResult` for test use. The fileURL points to a
    /// path that does not need to exist — ManifestBuilder reads only the metadata.
    private static let fakeMesh = MeshExportResult(
        fileURL: URL(fileURLWithPath: "/tmp/arkit_mesh.obj"),
        vertexCount: 42,
        faceCount: 18
    )

    private static let fixedDate: Date = {
        // 2026-05-28T14:33:30Z — the "ended" timestamp in the fixture.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 28,
                                             hour: 14, minute: 33, second: 30))!
    }()

    private static let startDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 28,
                                             hour: 14, minute: 32, second: 0))!
    }()

    private func makeBuilder(
        captures: [CaptureEntry] = [],
        originFix: LocationFix? = nil,
        latestFix: LocationFix? = nil
    ) -> ManifestBuilder {
        ManifestBuilder(
            sessionID: "fixed-session-id",
            startedAt: Self.startDate,
            jobID: "fixed-job-id",
            captures: captures,
            originFix: originFix,
            latestFix: latestFix,
            deviceInfo: DeviceInfo(
                model: "Test Device", modelIdentifier: "Tester1,1",
                osVersion: "99.0", appVersion: "0.0.1"
            ),
            clock: FixedClock(date: Self.fixedDate, id: "fixed-session-id"),
            mesh: Self.fakeMesh
        )
    }

    // MARK: - Tests

    func testBuildProducesCorrectSessionID() {
        let manifest = makeBuilder().build()
        XCTAssertEqual(manifest.sessionID, "fixed-session-id")
    }

    func testBuildProducesCorrectJobID() {
        let manifest = makeBuilder().build()
        XCTAssertEqual(manifest.jobID, "fixed-job-id")
    }

    /// `endedAt` must come from the clock's `now()`, not from `startedAt`.
    func testBuildEndedAtComesFromClock() {
        let manifest = makeBuilder().build()
        // The fixed clock returns fixedDate; iso8601 formatter renders it as:
        XCTAssertEqual(manifest.endedAt, "2026-05-28T14:33:30.000Z")
    }

    func testBuildStartedAtMatchesStartDate() {
        let manifest = makeBuilder().build()
        XCTAssertEqual(manifest.startedAt, "2026-05-28T14:32:00.000Z")
    }

    /// When both `originFix` and `latestFix` are nil there is no GPS information;
    /// `gpsOrigin` must be nil (and omitted from JSON — tested in
    /// ManifestSerializationTests.testNoGPSManifestOmitsGPSKeysInJSON).
    func testBuildGPSOriginIsNilWhenBothFixesNil() {
        let manifest = makeBuilder(originFix: nil, latestFix: nil).build()
        XCTAssertNil(manifest.gpsOrigin)
    }

    /// When `originFix` is provided it becomes `gpsOrigin`.
    func testBuildGPSOriginFromOriginFix() {
        let fix = LocationFix(
            latitude: 40.808, longitude: -96.706, altitudeM: 360.0,
            horizontalAccuracyM: 3.5, verticalAccuracyM: 5.0,
            timestamp: Self.startDate, degraded: false
        )
        let manifest = makeBuilder(originFix: fix).build()
        let origin = manifest.gpsOrigin
        XCTAssertNotNil(origin)
        XCTAssertEqual(origin?.latitude ?? 0, 40.808, accuracy: 1e-9)
        XCTAssertEqual(origin?.longitude ?? 0, -96.706, accuracy: 1e-9)
        XCTAssertEqual(origin?.altitudeM ?? 0, 360.0, accuracy: 1e-9)
    }

    /// When `originFix` is nil but `latestFix` is not, `latestFix` is used as
    /// the GPS origin (the fallback path).
    func testBuildGPSOriginFallsBackToLatestFix() {
        let fix = LocationFix(
            latitude: 51.5, longitude: -0.1, altitudeM: 10.0,
            horizontalAccuracyM: 8.0, verticalAccuracyM: 12.0,
            timestamp: Self.startDate, degraded: true
        )
        let manifest = makeBuilder(originFix: nil, latestFix: fix).build()
        XCTAssertNotNil(manifest.gpsOrigin)
        XCTAssertEqual(manifest.gpsOrigin?.latitude ?? 0, 51.5, accuracy: 1e-9)
    }

    func testBuildWorldMeshMetadataMatchesMeshResult() {
        let manifest = makeBuilder().build()
        XCTAssertEqual(manifest.worldMesh.vertexCount, 42)
        XCTAssertEqual(manifest.worldMesh.faceCount, 18)
        XCTAssertEqual(manifest.worldMesh.filename, "arkit_mesh.obj")
        XCTAssertEqual(manifest.worldMesh.coordinateFrame, "arkit_session_local")
    }

    func testBuildCapturesArePropagatedUnchanged() {
        let captures = ManifestFixtures.make().captures
        let manifest = makeBuilder(captures: captures).build()
        XCTAssertEqual(manifest.captures.count, 8)
        XCTAssertEqual(manifest.captures[0].promptLabel, .frontLeftCorner)
    }

    func testManifestVersionIsAlways1_0_0() {
        let manifest = makeBuilder().build()
        XCTAssertEqual(manifest.manifestVersion, "1.0.0")
    }
}
