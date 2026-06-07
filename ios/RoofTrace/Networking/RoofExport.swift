import CoreLocation
import Foundation

// Facet vertices are [lat, lng] with an OPTIONAL 3rd elevation element
// (json_export 1.2.0). Take the first two for the horizontal coordinate; a 3rd
// element is read separately (see Facet.vertices3D).
func coordFromFacetVertex(_ vertex: [Double]) -> CLLocationCoordinate2D? {
    guard vertex.count >= 2 else { return nil }
    return coordinate(latitude: vertex[0], longitude: vertex[1])
}

func coordFromGeoJSON(_ vertex: [Double]) -> CLLocationCoordinate2D? {
    guard vertex.count == 2 else { return nil }
    return coordinate(latitude: vertex[1], longitude: vertex[0])
}

private func coordinate(latitude: Double, longitude: Double) -> CLLocationCoordinate2D? {
    guard latitude.isFinite, longitude.isFinite else { return nil }
    guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

struct RoofExport: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = "1.2.0"

    let schemaVersion: String
    let job: Job
    let measurement: Measurement?
    let provenance: Provenance?
    let artifacts: Artifacts

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case job
        case measurement
        case provenance
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported report schema version"
            )
        }
        job = try container.decode(Job.self, forKey: .job)
        measurement = try container.decodeIfPresent(Measurement.self, forKey: .measurement)
        provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance)
        artifacts = try container.decode(Artifacts.self, forKey: .artifacts)
    }
}

extension RoofExport {
    struct Job: Codable, Equatable, Sendable {
        let id: String
        let address: String?
        let status: String
    }

    struct Measurement: Decodable, Equatable, Sendable {
        let generatedAt: Date?
        let source: String?
        let confidence: Double?
        let totalAreaSqFt: Double?
        let totalPerimeterFt: Double?
        let predominantPitchRatio: Double?
        let predominantPitchDegrees: Double?
        let warnings: [String]
        let facets: [Facet]
        let features: [Feature]
        let geocode: Geocode?
        let onSiteVisualizations: [OnSiteVisualization]
        let footprint: GeoJSONPolygon?
        let roofOutline: GeoJSONPolygon?

        private enum CodingKeys: String, CodingKey {
            case generatedAt
            case source
            case confidence
            case totalAreaSqFt
            case totalPerimeterFt
            case predominantPitchRatio
            case predominantPitchDegrees
            case warnings
            case facets
            case features
            case geocode
            case onSiteVisualizations
            case footprint
            case roofOutline
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            totalAreaSqFt = try container.decodeIfPresent(Double.self, forKey: .totalAreaSqFt)
            totalPerimeterFt = try container.decodeIfPresent(Double.self, forKey: .totalPerimeterFt)
            predominantPitchRatio = try container.decodeIfPresent(Double.self, forKey: .predominantPitchRatio)
            predominantPitchDegrees = try container.decodeIfPresent(Double.self, forKey: .predominantPitchDegrees)
            warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
            facets = try container.decodeIfPresent([Facet].self, forKey: .facets) ?? []
            features = try container.decodeIfPresent([Feature].self, forKey: .features) ?? []
            geocode = try container.decodeIfPresent(Geocode.self, forKey: .geocode)
            onSiteVisualizations = try container.decodeIfPresent([OnSiteVisualization].self, forKey: .onSiteVisualizations) ?? []
            footprint = try container.decodeIfPresent(GeoJSONPolygon.self, forKey: .footprint)
            roofOutline = try container.decodeIfPresent(GeoJSONPolygon.self, forKey: .roofOutline)
        }
    }

    struct Facet: Decodable, Equatable, Identifiable, Sendable {
        let facetID: String
        let vertices: [[Double]]
        let pitchRatio: Double?
        let pitchDegrees: Double?
        let areaSqFt: Double?
        let source: String?
        let confidence: Double?

        var id: String { facetID }

        var coordinates: [CLLocationCoordinate2D] {
            vertices.compactMap(coordFromFacetVertex)
        }

        /// Each vertex as a horizontal coordinate plus its optional elevation in
        /// metres (the 3rd export element, present on the LiDAR plane-fit path —
        /// json_export 1.2.0). nil elevation means imagery-only (flat) geometry.
        var vertices3D: [(coordinate: CLLocationCoordinate2D, elevationM: Double?)] {
            vertices.compactMap { vertex in
                guard let coordinate = coordFromFacetVertex(vertex) else { return nil }
                let elevation = vertex.count >= 3 && vertex[2].isFinite ? vertex[2] : nil
                return (coordinate, elevation)
            }
        }

        /// True when at least one vertex carries a real elevation — i.e. this
        /// facet can render as a true tilted plane rather than flat.
        var hasElevation: Bool {
            vertices.contains { $0.count >= 3 && $0[2].isFinite }
        }

        private enum CodingKeys: String, CodingKey {
            case facetID = "facetId"
            case vertices
            case pitchRatio
            case pitchDegrees
            case areaSqFt
            case source
            case confidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            facetID = try container.decode(String.self, forKey: .facetID)
            let rawVertices = try container.decodeIfPresent([LossyVertex].self, forKey: .vertices) ?? []
            vertices = rawVertices.map(\.values)
            pitchRatio = try container.decodeIfPresent(Double.self, forKey: .pitchRatio)
            pitchDegrees = try container.decodeIfPresent(Double.self, forKey: .pitchDegrees)
            areaSqFt = try container.decodeIfPresent(Double.self, forKey: .areaSqFt)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        }
    }

    struct Feature: Codable, Equatable, Identifiable, Sendable {
        let label: String
        let bboxNorm: [Double]
        let verified: Bool
        let source: String?
        let confidence: Double?

        var id: String {
            "\(label)-\(bboxNorm.map { String($0) }.joined(separator: "-"))"
        }
    }

    struct Geocode: Codable, Equatable, Sendable {
        let lat: Double?
        let lng: Double?
        let confidence: Double?

        var coordinate: CLLocationCoordinate2D? {
            guard let lat, let lng else { return nil }
            return coordFromFacetVertex([lat, lng])
        }
    }

    struct OnSiteVisualization: Codable, Equatable, Sendable {
        let photoURL: URL?
        let compositeURL: URL?
        let overlaySVGURL: URL?
        let poseConfidence: Double?

        private enum CodingKeys: String, CodingKey {
            case photoURL = "photoUrl"
            case compositeURL = "compositeUrl"
            case overlaySVGURL = "overlaySvgUrl"
            case poseConfidence
        }
    }

    struct GeoJSONPolygon: Codable, Equatable, Sendable {
        let type: String?
        let coordinates: [[[Double]]]

        var exteriorCoordinates: [CLLocationCoordinate2D] {
            coordinates.first?.compactMap(coordFromGeoJSON) ?? []
        }
    }

    struct Provenance: Decodable, Equatable, Sendable {
        let attributions: JSONValue?
        let retrievedAt: JSONValue?
        let detector: String?
        let sam2Backend: String?
        let lidarWorkUnit: JSONValue?
        let pipelineSchemaVersion: String?
        let generatedAt: JSONValue?

        var attributionNames: [String] {
            attributions?.strings(forKey: "name") ?? []
        }
    }

    struct Artifacts: Codable, Equatable, Sendable {
        let pdfURL: URL?
        let shareURL: URL?
        let lidarPointsURL: URL?
        let model3DURL: URL?

        private enum CodingKeys: String, CodingKey {
            case pdfURL = "pdfUrl"
            case shareURL = "shareUrl"
            case lidarPointsURL = "lidarPointsUrl"
            case model3DURL = "model3DUrl"
        }
    }
}

private struct LossyVertex: Decodable, Equatable, Sendable {
    let values: [Double]

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), container.decodeNil() {
            values = []
            return
        }
        values = (try? [Double](from: decoder)) ?? []
    }
}

enum JSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func strings(forKey key: String) -> [String] {
        switch self {
        case .object(let object):
            let current = object[key].flatMap { value -> String? in
                if case .string(let string) = value {
                    return string
                }
                return nil
            }
            return [current].compactMap { $0 } + object.values.flatMap { $0.strings(forKey: key) }
        case .array(let values):
            return values.flatMap { $0.strings(forKey: key) }
        case .string, .number, .bool, .null:
            return []
        }
    }
}
