import SwiftUI
import AuthenticationServices
import MyNoteCore

struct SignInView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(isCreatingAccount ? "Create an account" : "Sign in")
                        .font(theme.current.font(.heading2))
                        .foregroundStyle(theme.current.textPrimary)
                    Text("Only needed for syncing and for carrying purchases between devices. Your notes already work without it.")
                        .font(theme.current.font(.caption))
                        .foregroundStyle(theme.current.textSecondary)
                        .multilineTextAlignment(.center)
                }

                SignInWithAppleButton(.signIn) { _ in
                    // The request is configured inside AuthManager so the nonce
                    // and the Firebase credential are built in one place.
                } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .allowsHitTesting(false)
                    .overlay {
                        Button { Task { await app.auth.signInWithApple() } } label: {
                            Color.clear
                        }
                        .accessibilityLabel("Sign in with Apple")
                    }

                Button {
                    Task { await app.auth.signInWithGoogle() }
                } label: {
                    Label("Continue with Google", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Divider().overlay(theme.current.border)

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(isCreatingAccount ? .newPassword : .password)
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    Task {
                        if isCreatingAccount {
                            await app.auth.signUp(email: email, password: password)
                        } else {
                            await app.auth.signIn(email: email, password: password)
                        }
                        if app.auth.isSignedIn { dismiss() }
                    }
                } label: {
                    if app.auth.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(isCreatingAccount ? "Create account" : "Sign in")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(email.isEmpty || password.isEmpty || app.auth.isWorking)

                if let error = app.auth.lastError {
                    Text(error)
                        .font(theme.current.font(.caption))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button(isCreatingAccount ? "I already have an account" : "Create an account") {
                        isCreatingAccount.toggle()
                    }
                    if !isCreatingAccount && !email.isEmpty {
                        Button("Reset password") {
                            Task { await app.auth.sendPasswordReset(email: email) }
                        }
                    }
                }
                .font(theme.current.font(.caption))
            }
            .padding(24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background(theme.current.background)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: app.auth.status) { _, status in
            if case .signedIn = status { dismiss() }
        }
    }
}
