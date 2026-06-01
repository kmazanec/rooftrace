import SwiftUI

/// One-time LiDAR setup check: "point at a wall ~1 m away." Probes the AR
/// session for `sceneDepth`; passes to the first prompt, or routes to the
/// unsupported-device terminal state with a clear message.
struct SetupCheckView: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(
                    eyebrow: "Capture setup",
                    title: "Checking LiDAR",
                    subtitle: "Point the phone at a wall about 1 meter away while we verify the depth sensor."
                )

                Card {
                    VStack(spacing: 18) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(Color.CC.blue)
                        ProgressView()
                            .tint(Color.CC.blue)
                        Text("Keep the device steady")
                            .font(.RoofTrace.bodyMedium)
                            .foregroundStyle(Color.CC.ink75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Spacer()
            }
            .padding(20)
        }
        .task {
            await model.runSetupCheck()
        }
    }
}

/// Terminal screen for non-LiDAR devices.
struct LidarUnsupportedView: View {
    let message: String

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(
                    eyebrow: "Capture setup",
                    title: "Device not supported",
                    subtitle: message
                )

                InlineErrorBlock(message: "Use an iPhone Pro or iPad Pro with LiDAR to complete the scan.")
                Spacer()
            }
            .padding(20)
        }
    }
}
