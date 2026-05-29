import SwiftUI

/// One-time LiDAR setup check: "point at a wall ~1 m away." Probes the AR
/// session for `sceneDepth`; passes to the first prompt, or routes to the
/// unsupported-device terminal state with a clear message.
struct SetupCheckView: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Checking LiDAR")
                .font(.title2).bold()
            Text("Point the phone at a wall about 1 meter away. We're verifying the depth sensor.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
            Spacer()
        }
        .padding()
        .task {
            await model.runSetupCheck()
        }
    }
}

/// Terminal screen for non-LiDAR devices.
struct LidarUnsupportedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Device not supported")
                .font(.title2).bold()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }
}
