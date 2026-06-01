import SwiftUI

struct PrimaryButton: View {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(Color.CC.chalk)
                }
            Text(isLoading ? "Signing In" : title)
                    .font(.RoofTrace.button)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .foregroundStyle(Color.CC.chalk)
            .background((isDisabled || isLoading) ? Color.CC.ink55 : Color.CC.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
    }
}
