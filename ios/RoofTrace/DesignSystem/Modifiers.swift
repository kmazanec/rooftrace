import SwiftUI

struct AppTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.RoofTrace.body)
            .foregroundStyle(Color.CC.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.CC.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.CC.lineMid, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func appTextField() -> some View {
        textFieldStyle(AppTextFieldStyle())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
