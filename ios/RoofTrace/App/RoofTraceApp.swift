import SwiftUI

/// App entry point. Owns the `CaptureViewModel`, registers the deep-link handler,
/// and routes the active view off `CaptureSessionState`.
@main
struct RoofTraceApp: App {
    @State private var model: CaptureViewModel

    init() {
        // On a real device the ARKit sensor manager is injected; in the simulator
        // `canImport(ARKit)` still holds but the device lacks LiDAR, so the setup
        // check fails gracefully into the unsupported state.
        #if canImport(ARKit) && !targetEnvironment(simulator)
        let sensors: CaptureSensing? = ARKitSessionManager()
        #else
        let sensors: CaptureSensing? = nil
        #endif
        _model = State(initialValue: CaptureViewModel(
            sensors: sensors,
            location: GPSProvider()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    model.applyDeepLink(url)
                }
        }
    }
}

/// Routes the visible view from the capture state machine.
struct RootView: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        switch model.state {
        case .tokenEntry:
            TokenEntryView(model: model)
        case .setupCheck:
            SetupCheckView(model: model)
        case .capturePrompt:
            if let prompt = model.currentPrompt {
                CapturePromptView(model: model, prompt: prompt)
            } else {
                // Unreachable: the state machine only enters `.capturePrompt(i)`
                // for an in-range prompt index, so `currentPrompt` is non-nil
                // here. Surface it loudly in DEBUG rather than render blank.
                #if DEBUG
                Text("Internal error: no prompt for the current capture step.")
                    .foregroundStyle(.red)
                #else
                EmptyView()
                #endif
            }
        case .uploading, .uploadComplete, .uploadFailed, .bundleSaved:
            UploadProgressView(model: model)
        case .lidarUnsupported:
            LidarUnsupportedView(
                message: model.errorMessage
                    ?? "This app requires an iPhone Pro or iPad Pro with LiDAR.")
        }
    }
}
