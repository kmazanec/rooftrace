import SwiftUI

struct EyebrowLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.RoofTrace.label)
            .foregroundStyle(Color.CC.orange)
    }
}
