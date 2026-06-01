import SwiftUI

@Observable
@MainActor
final class LoginViewModel {
    var username = ""
    var password = ""
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?

    private let auth: AuthStore
    private let router: AppRouter

    var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    init(auth: AuthStore, router: AppRouter) {
        self.auth = auth
        self.router = router
    }

    func signIn() async {
        guard canSubmit, !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            try await auth.signIn(username: username, password: password)
            _ = router.replayStashedRouteIfAuthenticated(auth.isAuthenticated)
        } catch APIError.unauthorized {
            errorMessage = "Those credentials did not match. Check the username and password, then try again."
        } catch {
            errorMessage = "Sign in failed. Check your connection and try again."
        }
    }
}

struct LoginView: View {
    @Bindable var model: LoginViewModel

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ScreenHeader(
                        eyebrow: "RoofTrace",
                        title: "Measure roofs from the field.",
                        subtitle: "Sign in with your demo account to create jobs, capture scans, and review reports."
                    )

                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Username")
                                    .font(.RoofTrace.label)
                                    .foregroundStyle(Color.CC.ink75)
                                TextField("demo@example.com", text: $model.username)
                                    .appTextField()
                                    .textContentType(.username)
                                    .keyboardType(.emailAddress)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Password")
                                    .font(.RoofTrace.label)
                                    .foregroundStyle(Color.CC.ink75)
                                SecureField("Password", text: $model.password)
                                    .appTextField()
                                    .textContentType(.password)
                            }

                            if let message = model.errorMessage {
                                InlineErrorBlock(message: message)
                            }

                            PrimaryButton(
                                title: "Sign In",
                                isLoading: model.isSigningIn,
                                isDisabled: !model.canSubmit,
                                action: {
                                    Task { await model.signIn() }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
            }
        }
    }
}
