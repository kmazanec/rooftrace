import SwiftUI

struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background(Color.CC.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.CC.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
