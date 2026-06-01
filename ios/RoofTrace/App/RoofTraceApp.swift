import SwiftUI

/// App entry point. Owns the `CaptureViewModel`, registers the deep-link handler,
/// and routes the active view off `CaptureSessionState`.
@main
struct RoofTraceApp: App {
    @State private var environment: AppEnvironment
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
        _environment = State(initialValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment, captureModel: model)
                .onOpenURL { url in
                    environment.router.handle(url: url, isAuthenticated: environment.auth.isAuthenticated)
                    if environment.auth.isAuthenticated {
                        model.applyDeepLink(url)
                    }
                }
                .preferredColorScheme(.light)
                .task {
                    await environment.auth.bootstrap()
                    _ = environment.router.replayStashedRouteIfAuthenticated(environment.auth.isAuthenticated)
                }
        }
    }
}

struct AppRootView: View {
    let environment: AppEnvironment
    let captureModel: CaptureViewModel

    var body: some View {
        if environment.auth.isAuthenticated {
            AuthenticatedRootView(
                environment: environment,
                captureModel: captureModel
            )
        } else {
            LoginContainerView(auth: environment.auth, router: environment.router)
        }
    }
}

struct LoginContainerView: View {
    @State private var model: LoginViewModel

    init(auth: AuthStore, router: AppRouter) {
        _model = State(initialValue: LoginViewModel(auth: auth, router: router))
    }

    var body: some View {
        LoginView(model: model)
    }
}

struct AuthenticatedRootView: View {
    let environment: AppEnvironment
    let captureModel: CaptureViewModel

    var body: some View {
        @Bindable var router = environment.router
        NavigationStack(path: $router.path) {
            JobListView(
                api: environment.api,
                authStore: environment.auth,
                router: environment.router
            )
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .jobDetail(let id):
                        Text("Job \(id)")
                            .font(.RoofTrace.body)
                            .foregroundStyle(Color.CC.ink)
                    case .createJob:
                        CreateJobView(
                            model: CreateJobViewModel(
                                api: environment.api,
                                authStore: environment.auth,
                                router: environment.router,
                                addressCompleter: MapKitAddressCompleter(),
                                locationResolver: CoreLocationResolver()
                            )
                        )
                    case .capture(let handoff):
                        CaptureRouteView(model: captureModel, handoff: handoff)
                    case .report(let jobID):
                        ReportRouteView(jobID: jobID, api: environment.api)
                    }
                }
        }
    }
}

struct CaptureRouteView: View {
    @Bindable var model: CaptureViewModel
    let handoff: CaptureHandoff

    var body: some View {
        CaptureRootView(model: model)
            .onAppear {
                guard model.state == .tokenEntry else { return }
                model.tokenInput = handoff.token
                if let jobID = handoff.jobID {
                    model.jobIDInput = jobID
                }
            }
    }
}

/// Routes the visible view from the capture state machine.
struct CaptureRootView: View {
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
                    .foregroundStyle(Color.CC.orangeHigh)
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
