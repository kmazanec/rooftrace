import SwiftUI

/// App entry point. Registers the deep-link handler and hosts the authenticated
/// navigation graph.
@main
struct RoofTraceApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment)
                .onOpenURL { url in
                    environment.router.handle(url: url, isAuthenticated: environment.auth.isAuthenticated)
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

    var body: some View {
        if environment.auth.isAuthenticated {
            AuthenticatedRootView(environment: environment)
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
                        JobStatusView(
                            model: StatusPollViewModel(
                                jobID: id,
                                api: environment.api,
                                authStore: environment.auth
                            ),
                            router: environment.router
                        )
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
                        CaptureFlowView(handoff: handoff, router: environment.router)
                    case .report(let jobID):
                        ReportRouteView(jobID: jobID, api: environment.api, router: environment.router)
                    }
                }
        }
    }
}

struct CaptureFlowView: View {
    @Bindable var router: AppRouter
    @State private var model: CaptureViewModel

    init(handoff: CaptureHandoff, router: AppRouter) {
        self.router = router

        #if canImport(ARKit) && !targetEnvironment(simulator)
        let sensors: CaptureSensing? = ARKitSessionManager()
        #else
        let sensors: CaptureSensing? = nil
        #endif
        _model = State(initialValue: CaptureViewModel(
            handoff: handoff,
            sensors: sensors,
            location: GPSProvider()
        ))
    }

    var body: some View {
        CaptureRootView(model: model)
            .onChange(of: model.state) { _, state in
                guard state == .uploadComplete else { return }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    router.pop()
                }
            }
    }
}

/// Routes the visible view from the capture state machine.
struct CaptureRootView: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        switch model.state {
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
