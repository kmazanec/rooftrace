import SwiftUI

/// Token + job_id entry. The Start button is disabled until both validate. A
/// `rooftrace://capture?token=...&job_id=...` deep link pre-fills both fields.
struct TokenEntryView: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("RoofTrace Capture")
                .font(.largeTitle).bold()
            Text("Enter the capture token from the RoofTrace web app, or open the link it gave you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Capture token (32 characters)", text: $model.tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: model.tokenInput) { _, new in
                        if new.count > 32 { model.tokenInput = String(new.prefix(32)) }
                    }
                if !model.tokenInput.isEmpty && !TokenValidator.isValid(model.tokenInput) {
                    Text("Token must be 32 base58 characters.")
                        .font(.caption).foregroundStyle(.red)
                }

                TextField("Job ID (UUID)", text: $model.jobIDInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !model.jobIDInput.isEmpty && !TokenValidator.isValidJobID(model.jobIDInput) {
                    Text("Job ID must be a valid UUID.")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Button {
                model.startSetupCheck()
            } label: {
                Text("Start Capture").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStart)

            Spacer()
        }
        .padding()
    }
}
