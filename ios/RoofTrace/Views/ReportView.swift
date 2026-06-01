import MapKit
import SwiftUI

struct ReportRouteView: View {
    @State private var model: ReportViewModel

    init(jobID: String, api: any APIClientProtocol) {
        _model = State(initialValue: ReportViewModel(jobID: jobID, api: api))
    }

    var body: some View {
        ReportView(model: model)
            .task {
                await model.load()
            }
    }
}

struct ReportView: View {
    @Bindable var model: ReportViewModel

    var body: some View {
        ZStack {
            Color.Brand.gray50.ignoresSafeArea()

            switch model.state {
            case .loading:
                ProgressView("Loading report")
                    .font(.RoofTrace.body)
                    .foregroundStyle(Color.Brand.gray700)
            case .notReady:
                ReportMessageView(
                    title: "Report not ready",
                    message: "This job does not have a measurement yet."
                )
            case .error(let message):
                ReportMessageView(
                    title: "Report unavailable",
                    message: message,
                    retry: { Task { await model.load() } }
                )
            case .ready(let export):
                ReadyReportView(export: export, model: model)
            }
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReadyReportView: View {
    let export: RoofExport
    @Bindable var model: ReportViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ReportHeader(export: export)

                if let measurement = export.measurement {
                    ReportMapView(model: model, measurement: measurement)
                    MeasurementSummary(measurement: measurement)
                    FacetTable(model: model, facets: measurement.facets)
                    FeatureTable(features: measurement.features)
                    WarningTable(warnings: measurement.warnings)
                    AttributionTable(export: export)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
    }
}

private struct ReportHeader: View {
    let export: RoofExport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(export.job.address ?? "Roof report")
                    .font(.RoofTrace.title)
                    .foregroundStyle(Color.Brand.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
                Text(export.job.id)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.Brand.gray600)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let shareURL = export.artifacts.shareURL {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.RoofTrace.button)
                        .foregroundStyle(Color.Brand.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.Brand.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Share public report")
            }
        }
    }
}

private struct ReportMapView: View {
    @Bindable var model: ReportViewModel
    let measurement: RoofExport.Measurement
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Roof Map", subtitle: "\(measurement.facets.count) facets")

            Map(position: $position, interactionModes: [.pan, .zoom]) {
                if measurement.displayFootprintCoordinates.count >= 3 {
                    MapPolygon(coordinates: measurement.displayFootprintCoordinates)
                        .foregroundStyle(Color.Brand.charcoal.opacity(0.08))
                        .stroke(Color.Brand.gray700, lineWidth: 2)
                }

                ForEach(Array(measurement.facets.enumerated()), id: \.element.facetID) { index, facet in
                    if facet.coordinates.count >= 3 {
                        let selected = model.selectedFacetID == facet.facetID
                        MapPolygon(coordinates: facet.coordinates)
                            .foregroundStyle(Color.Brand.charcoal.opacity(selected ? 0.34 : 0.18))
                            .stroke(Color.Brand.white, lineWidth: selected ? 3 : 1.5)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.Brand.gray300, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mapAccessibilityLabel)
            .accessibilityValue(mapAccessibilityValue)
            .onAppear(perform: fitMap)
            .onChange(of: model.selectedFacetID) { _, _ in fitMap() }
        }
    }

    private var mapAccessibilityLabel: String {
        "Roof map"
    }

    private var mapAccessibilityValue: String {
        let selected = measurement.facets.first { $0.facetID == model.selectedFacetID }?.facetID ?? "none"
        return "\(measurement.facets.count) facets. Selected facet \(selected)."
    }

    private func fitMap() {
        if let rect = model.mapRect {
            position = .rect(rect)
        }
    }
}

private struct MeasurementSummary: View {
    let measurement: RoofExport.Measurement

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Measurements")
            VStack(alignment: .leading, spacing: 16) {
                StatProbe(
                    label: "Total area",
                    value: Formatters.squareFeet(measurement.totalAreaSqFt),
                    unit: "sq ft",
                    isHero: true
                )

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    StatProbe(label: "Perimeter", value: Formatters.feet(measurement.totalPerimeterFt), unit: "ft")
                    StatProbe(label: "Pitch", value: Formatters.pitch(measurement.predominantPitchRatio), unit: nil)
                    StatProbe(label: "Degrees", value: Formatters.degrees(measurement.predominantPitchDegrees), unit: nil)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CONFIDENCE")
                            .font(.RoofTrace.label)
                            .foregroundStyle(Color.Brand.gray600)
                        ConfidenceChip(confidence: measurement.confidence)
                    }
                }
            }
            .reportPanel()
        }
    }
}

private struct FacetTable: View {
    @Bindable var model: ReportViewModel
    let facets: [RoofExport.Facet]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Facets")
            VStack(spacing: 0) {
                ForEach(Array(facets.enumerated()), id: \.element.facetID) { index, facet in
                    Button {
                        model.selectedFacetID = facet.facetID
                    } label: {
                        FacetRow(index: index, facet: facet, isSelected: model.selectedFacetID == facet.facetID)
                    }
                    .buttonStyle(.plain)

                    if index < facets.count - 1 {
                        Divider().background(Color.Brand.gray200)
                    }
                }
            }
            .reportPanel(padding: 0)
        }
    }
}

private struct FacetRow: View {
    let index: Int
    let facet: RoofExport.Facet
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FacetSwatch(index: index, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 4) {
                Text(facet.facetID)
                    .font(.RoofTrace.label)
                    .foregroundStyle(Color.Brand.charcoal)
                Text("\(Formatters.squareFeet(facet.areaSqFt)) sq ft · pitch \(Formatters.pitch(facet.pitchRatio)) · \(Formatters.degrees(facet.pitchDegrees))")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.Brand.gray700)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ConfidenceChip(confidence: facet.confidence)
        }
        .padding(14)
        .background(isSelected ? Color.Brand.gray100 : Color.Brand.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        "\(facet.facetID), \(Formatters.squareFeet(facet.areaSqFt)) square feet, pitch \(Formatters.pitch(facet.pitchRatio)), confidence \(ConfidenceLevel(facet.confidence).label)"
    }
}

private struct FeatureTable: View {
    let features: [RoofExport.Feature]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Features", subtitle: "Image-space detections")
            VStack(spacing: 0) {
                if features.isEmpty {
                    EmptyTableRow(text: "No detected roof features")
                } else {
                    ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                        FeatureRow(feature: feature)
                        if index < features.count - 1 {
                            Divider().background(Color.Brand.gray200)
                        }
                    }
                }
            }
            .reportPanel(padding: 0)
        }
    }
}

private struct FeatureRow: View {
    let feature: RoofExport.Feature

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.label.capitalized)
                    .font(.RoofTrace.label)
                    .foregroundStyle(Color.Brand.charcoal)
                Text(feature.verified ? "verified" : "unverified")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.Brand.gray700)
            }
            Spacer(minLength: 8)
            ConfidenceChip(confidence: feature.confidence)
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(feature.label), \(feature.verified ? "verified" : "unverified"), confidence \(ConfidenceLevel(feature.confidence).label)")
    }
}

private struct WarningTable: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Warnings")
            VStack(alignment: .leading, spacing: 8) {
                if warnings.isEmpty {
                    Text("No warnings")
                        .font(.RoofTrace.body)
                        .foregroundStyle(Color.Brand.gray700)
                } else {
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.Brand.gray800)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .reportPanel()
        }
    }
}

private struct AttributionTable: View {
    let export: RoofExport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Attributions")
            VStack(alignment: .leading, spacing: 8) {
                let names = export.provenance?.attributionNames.uniqued() ?? []
                if names.isEmpty {
                    Text("No attributions provided")
                        .font(.RoofTrace.body)
                        .foregroundStyle(Color.Brand.gray700)
                } else {
                    ForEach(names, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.Brand.gray800)
                    }
                }
            }
            .reportPanel()
        }
    }
}

private struct EmptyTableRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.RoofTrace.body)
            .foregroundStyle(Color.Brand.gray700)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

private struct ReportMessageView: View {
    let title: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.RoofTrace.title)
                .foregroundStyle(Color.Brand.charcoal)
            Text(message)
                .font(.RoofTrace.body)
                .foregroundStyle(Color.Brand.gray700)
            if let retry {
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.RoofTrace.button)
                }
                .foregroundStyle(Color.Brand.charcoal)
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum Formatters {
    static func squareFeet(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    static func feet(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    static func pitch(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))/12"
    }

    static func degrees(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))°"
    }
}

private extension View {
    func reportPanel(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Brand.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.Brand.gray200, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
