import SwiftUI

struct CreateJobView: View {
    @State var model: CreateJobViewModel

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(
                        eyebrow: "New measurement",
                        title: "Property address",
                        subtitle: "Start with the address the server will verify."
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("123 Main Street", text: $model.address)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .font(.RoofTrace.body)
                            .padding(14)
                            .background(Color.CC.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.CC.lineMid, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onChange(of: model.address) { _, newValue in
                                Task { await model.searchAddress(newValue) }
                            }

                        typeahead
                    }

                    GhostButton(title: "Use my current location", systemImage: "location") {
                        Task { await model.useCurrentLocation() }
                    }

                    if let error = model.errorMessage {
                        InlineErrorBlock(message: error)
                    }

                    PrimaryButton(
                        title: "Start measurement",
                        isLoading: model.isSubmitting,
                        isDisabled: !model.canSubmit
                    ) {
                        Task { await model.submit() }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("New measurement")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var typeahead: some View {
        switch model.typeaheadState {
        case .tooShort:
            Text("Keep typing")
                .font(.RoofTrace.label)
                .foregroundStyle(Color.CC.ink55)
                .frame(minHeight: 32, alignment: .leading)
        case .searching:
            HStack(spacing: 10) {
                ProgressView()
                Text("Searching")
                    .font(.RoofTrace.label)
                    .foregroundStyle(Color.CC.ink75)
            }
            .frame(minHeight: 32, alignment: .leading)
        case .noMatches:
            Text("No matches. Check the address.")
                .font(.RoofTrace.label)
                .foregroundStyle(Color.CC.orangeHigh)
                .frame(minHeight: 32, alignment: .leading)
        case .results(let suggestions):
            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        model.select(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.title)
                                .font(.RoofTrace.bodyMedium)
                                .foregroundStyle(Color.CC.ink)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.RoofTrace.label)
                                    .foregroundStyle(Color.CC.ink55)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .buttonStyle(.plain)

                    if suggestion.id != suggestions.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color.CC.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.CC.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
