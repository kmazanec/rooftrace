import SwiftUI

struct HomeView: View {
    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(
                    eyebrow: "Home",
                    title: "Jobs",
                    subtitle: "Your measurement workspace is ready."
                )
                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("RoofTrace")
        .navigationBarTitleDisplayMode(.inline)
    }
}
