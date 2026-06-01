import Foundation
import MapKit
import Observation

enum ReportState: Equatable, Sendable {
    case loading
    case ready(RoofExport)
    case notReady
    case error(String)
}

@Observable
@MainActor
final class ReportViewModel {
    private let jobID: String
    private let api: any APIClientProtocol

    private(set) var state: ReportState = .loading
    var selectedFacetID: String?

    init(jobID: String, api: any APIClientProtocol) {
        self.jobID = jobID
        self.api = api
    }

    func load() async {
        state = .loading
        do {
            let export = try await api.report(id: jobID)
            state = Self.state(for: export)
            selectedFacetID = export.measurement?.facets.first?.facetID
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

    var mapRect: MKMapRect? {
        guard case .ready(let export) = state else { return nil }
        return Self.mapRect(for: export)
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
