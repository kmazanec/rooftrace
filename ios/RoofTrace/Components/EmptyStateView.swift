import SwiftUI

struct EmptyStateView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "house.lodge")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.CC.blue)
                .frame(width: 64, height: 64)
                .background(Color.CC.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 6) {
                Text("No measurements yet")
                    .font(.RoofTrace.headline)
                    .foregroundStyle(Color.CC.ink)
                Text("Start with a property address.")
                    .font(.RoofTrace.body)
                    .foregroundStyle(Color.CC.ink75)
            }
            .multilineTextAlignment(.center)

            PrimaryButton(title: "Start your first measurement", action: action)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.CC.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.CC.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
