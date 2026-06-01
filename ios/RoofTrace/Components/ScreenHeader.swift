import SwiftUI

struct ScreenHeader: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?

    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eyebrow {
                EyebrowLabel(eyebrow)
            }
            Text(title)
                .font(.RoofTrace.display)
                .foregroundStyle(Color.CC.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.RoofTrace.body)
                    .foregroundStyle(Color.CC.ink75)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
