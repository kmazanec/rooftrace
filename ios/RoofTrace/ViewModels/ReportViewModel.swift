import Foundation
import MapKit
import Observation

enum ReportState: Equatable, Sendable {
    case loading
    case ready(RoofExport)
    case notReady
    case error(String)
}

enum ReportViewMode: String, CaseIterable, Equatable, Sendable {
    case map
    case threeD

    var label: String {
        switch self {
        case .map: return "Map"
        case .threeD: return "3D"
        }
    }
}

enum LidarLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case unavailable
}

@Observable
@MainActor
final class ReportViewModel {
    let jobID: String
    private let api: any APIClientProtocol

    private(set) var state: ReportState = .loading
    var selectedFacetID: String?

    /// 3D viewer state. The point cloud is fetched lazily the first time the
    /// viewer needs it (matching the web's lazy LiDAR toggle).
    var viewMode: ReportViewMode = .map
    var showLidarPoints = false
    private(set) var lidarState: LidarLoadState = .idle
    private(set) var lidarPoints: [[Double]] = []

    /// Scan credential for the "improve with a scan" entry on the report page,
    /// recovered from the job status endpoint (which carries an unexpired
    /// capture_token). nil when the scan window has closed.
    private(set) var captureHandoff: CaptureHandoff?
    private let now: @Sendable () -> Date

    init(jobID: String, api: any APIClientProtocol, now: @escaping @Sendable () -> Date = { Date() }) {
        self.jobID = jobID
        self.api = api
        self.now = now
    }

    func load() async {
        state = .loading
        do {
            let export = try await api.report(id: jobID)
            state = Self.state(for: export)
            selectedFacetID = export.measurement?.facets.first?.facetID
            await loadCaptureHandoff()
        } catch APIError.unauthorized {
            state = .error("Sign in again to view this report.")
            selectedFacetID = nil
        } catch APIError.notFound {
            state = .error("Report not found.")
            selectedFacetID = nil
        } catch {
            state = .error("Report could not be loaded. Check your connection and try again.")
            selectedFacetID = nil
        }
    }

    /// Recover the scan credential from the job status endpoint so the report page
    /// can offer "improve with a scan". Best-effort: a failure just hides the
    /// entry, never breaks the report.
    private func loadCaptureHandoff() async {
        guard let status = try? await api.job(id: jobID) else { return }
        guard let token = status.captureToken, !token.isEmpty else { return }
        if let expiry = status.captureTokenExpiresAt, expiry <= now() { return }
        captureHandoff = CaptureHandoff(token: token, jobID: jobID)
    }

    var mapRect: MKMapRect? {
        guard case .ready(let export) = state else { return nil }
        return Self.mapRect(for: export)
    }

    private var export: RoofExport? {
        guard case .ready(let export) = state else { return nil }
        return export
    }

    /// True when the report advertises a fetchable LiDAR cloud (the server only
    /// emits the URL when one exists) — so the viewer can offer a points toggle.
    var lidarAvailable: Bool {
        export?.artifacts.lidarPointsURL != nil
    }

    /// True when any facet carries real per-vertex elevation, so the 3D view
    /// shows true tilted planes rather than a flat outline.
    var hasElevation: Bool {
        export?.measurement?.facets.contains(where: { $0.hasElevation }) ?? false
    }

    /// The projected metric scene for the SceneKit viewer, rebuilt from the
    /// current facets + (when shown) the fetched point cloud.
    var roofScene: RoofProjection.Scene {
        let facets = export?.measurement?.facets ?? []
        let points = showLidarPoints ? lidarPoints : []
        return RoofProjection.scene(facets: facets, lidarPoints: points)
    }

    /// Switch between the flat map and the 3D scene; fetches points lazily when
    /// the 3D points overlay is first enabled.
    func setViewMode(_ mode: ReportViewMode) {
        viewMode = mode
    }

    func toggleLidarPoints() async {
        showLidarPoints.toggle()
        if showLidarPoints {
            await loadLidarPointsIfNeeded()
        }
    }

    func loadLidarPointsIfNeeded() async {
        guard lidarAvailable, lidarState == .idle else { return }
        lidarState = .loading
        do {
            let response = try await api.lidarPoints(id: jobID)
            lidarPoints = response.points
            lidarState = response.hasPoints ? .loaded : .unavailable
        } catch {
            // The cloud is a non-essential enhancement; never surface an error
            // that breaks the report — just mark it unavailable (a quiet note).
            lidarPoints = []
            lidarState = .unavailable
        }
    }

    nonisolated static func state(for export: RoofExport) -> ReportState {
        export.measurement == nil ? .notReady : .ready(export)
    }

    nonisolated static func mapRect(for export: RoofExport) -> MKMapRect? {
        guard let measurement = export.measurement else { return nil }
        let coordinates = measurement.mapCoordinates
        guard let first = coordinates.first else { return nil }

        let firstPoint = MKMapPoint(first)
        let rect = coordinates.dropFirst().reduce(MKMapRect(origin: firstPoint, size: MKMapSize(width: 0, height: 0))) { partial, coordinate in
            partial.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }

        let padding = max(rect.size.width, rect.size.height, 80)
        return rect.insetBy(dx: -padding * 0.25, dy: -padding * 0.25)
    }
}

extension RoofExport.Measurement {
    var mapCoordinates: [CLLocationCoordinate2D] {
        let footprintCoordinates = footprint?.exteriorCoordinates ?? []
        let outlineCoordinates = roofOutline?.exteriorCoordinates ?? []
        let facetCoordinates = facets.flatMap(\.coordinates)
        return footprintCoordinates + outlineCoordinates + facetCoordinates
    }

    var displayFootprintCoordinates: [CLLocationCoordinate2D] {
        if let footprintCoordinates = footprint?.exteriorCoordinates, !footprintCoordinates.isEmpty {
            return footprintCoordinates
        }
        return facets.flatMap(\.coordinates)
    }
}
