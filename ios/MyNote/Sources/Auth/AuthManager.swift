import Foundation
import SwiftUI
import UIKit
import CommonCrypto
import AuthenticationServices
import FirebaseCore
import FirebaseAuth

/// Sign-in, backed by Firebase Auth.
///
/// Firebase is used for identity only — it is free for Google, Apple and email,
/// and it takes password resets, email verification and account recovery off our
/// plate entirely. Notes never touch Firebase; they go to our own Worker.
///
/// Signing in is always optional: MyNote is fully usable signed-out, and the
/// account exists so purchases and notes can follow the user to another device.
@Observable
@MainActor
final class AuthManager: NSObject {
    enum Status: Equatable {
        case signedOut
        case signedIn(uid: String, email: String?)
        /// No `GoogleService-Info.plist` in the bundle — local-only mode.
        case unconfigured
    }

    private(set) var status: Status = .signedOut
    private(set) var lastError: String?
    private(set) var isWorking = false

    private var handle: AuthStateDidChangeListenerHandle?
    private var appleNonce: String?
    private var appleContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        guard Self.isFirebaseConfigured else {
            status = .unconfigured
            return
        }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.status = user.map { .signedIn(uid: $0.uid, email: $0.email) } ?? .signedOut
            }
        }
    }

    /// The app ships without credentials so the repo stays safe to clone; a
    /// build with no plist runs local-only rather than crashing at launch.
    static var isFirebaseConfigured: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    /// Fresh ID token for the Worker. Firebase refreshes it automatically when
    /// it is close to expiry, so callers can ask on every request.
    func idToken() async throws -> String? {
        guard Self.isFirebaseConfigured, let user = Auth.auth().currentUser else { return nil }
        return try await user.getIDToken()
    }

    // MARK: - Email

    func signIn(email: String, password: String) async {
        await perform { try await Auth.auth().signIn(withEmail: email, password: password) }
    }

    func signUp(email: String, password: String) async {
        await perform { try await Auth.auth().createUser(withEmail: email, password: password) }
    }

    func sendPasswordReset(email: String) async {
        await perform { try await Auth.auth().sendPasswordReset(withEmail: email) }
    }

    // MARK: - Google

    /// Uses Firebase's web OAuth flow rather than the GoogleSignIn SDK — one
    /// fewer dependency, one fewer binary to keep current, same result.
    func signInWithGoogle() async {
        await perform {
            let provider = OAuthProvider(providerID: "google.com")
            provider.customParameters = ["prompt": "select_account"]
            let credential = try await provider.credential(with: nil)
            try await Auth.auth().signIn(with: credential)
        }
    }

    // MARK: - Apple

    /// Apple requires Sign in with Apple wherever another social login is
    /// offered, so this is a store-review requirement as much as a feature.
    func signInWithApple() async {
        let nonce = Self.randomNonce()
        appleNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await withCheckedThrowingContinuation { continuation in
                appleContinuation = continuation
                controller.performRequests()
            }
        } catch {
            lastError = Self.friendly(error)
        }
    }

    func signOut() {
        guard Self.isFirebaseConfigured else { return }
        try? Auth.auth().signOut()
    }

    // MARK: - Helpers

    private func perform(_ work: @escaping () async throws -> Void) async {
        guard Self.isFirebaseConfigured else {
            lastError = "Sign-in is not configured in this build."
            return
        }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            lastError = Self.friendly(error)
        }
    }

    /// Turn Firebase's error codes into something a person can act on.
    static func friendly(_ error: Error) -> String {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .wrongPassword, .invalidCredential:
            return "That email and password don't match."
        case .invalidEmail:
            return "That doesn't look like an email address."
        case .emailAlreadyInUse:
            return "There's already an account with that email. Try signing in."
        case .weakPassword:
            return "Pick a password with at least 6 characters."
        case .networkError:
            return "No connection. Your notes are saved on this device either way."
        case .tooManyRequests:
            return "Too many attempts. Wait a minute and try again."
        case .userNotFound:
            return "No account with that email yet."
        default:
            return error.localizedDescription
        }
    }

    /// A nonce binds Apple's response to this specific request, so a captured
    /// token cannot be replayed into our app.
    static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        let data = Array(input.utf8)
        CC_SHA256(data, CC_LONG(data.count), &hash)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

extension AuthManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = appleNonce
            else {
                finishApple(.failure(AuthError.appleTokenMissing))
                return
            }

            do {
                let firebaseCredential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: credential.fullName
                )
                try await Auth.auth().signIn(with: firebaseCredential)
                finishApple(.success(()))
            } catch {
                finishApple(.failure(error))
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in finishApple(.failure(error)) }
    }

    private func finishApple(_ result: Result<Void, Error>) {
        let continuation = appleContinuation
        appleContinuation = nil
        appleNonce = nil
        continuation?.resume(with: result)
    }
}

extension AuthManager: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}

enum AuthError: LocalizedError {
    case appleTokenMissing
    var errorDescription: String? { "Apple didn't return a sign-in token. Try again." }
}
