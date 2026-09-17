import Foundation
import AuthenticationServices
import CryptoKit
import MyNoteCore

/// Google sign-in for Drive access.
///
/// Implemented directly against Google's OAuth endpoints rather than through the
/// GoogleSignIn SDK. With Firebase gone this keeps the iOS app at **zero**
/// third-party dependencies, which means nothing to keep current, no extra
/// binary, and no analytics we did not write.
///
/// Uses the authorization-code flow with PKCE — the only correct choice for a
/// public client, since an app cannot keep a client secret.
@MainActor
final class GoogleAuth: NSObject {
    /// Per-file access to files this app created. Deliberately *not*
    /// `drive.readonly` or full `drive`: those are restricted scopes requiring
    /// a security assessment, and we have no business reading anything the user
    /// did not make here.
    static let scope = "https://www.googleapis.com/auth/drive.file"

    private let clientId: String
    private let redirectURI: String
    private let keychain = KeychainStore(service: "com.chrisphua.MyNote.google")

    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast

    init(clientId: String) {
        self.clientId = clientId
        // Google's convention for installed iOS apps: the client id reversed.
        self.redirectURI = "\(clientId.split(separator: ".").reversed().joined(separator: "."))://oauth"
        super.init()
    }

    var isSignedIn: Bool { keychain.refreshToken != nil }

    /// Present Google's consent screen and store the resulting refresh token.
    func signIn() async throws {
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Without this Google returns no refresh token on a repeat consent,
            // and the user would be sent back to the browser every hour.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback = try await present(components.url!)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw RemoteFolderError.needsReauthentication
        }

        try await exchange(parameters: [
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
    }

    func signOut() {
        keychain.refreshToken = nil
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    /// A valid access token, refreshed when it is close to expiry.
    func token() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let refresh = keychain.refreshToken else {
            throw RemoteFolderError.needsReauthentication
        }
        try await exchange(parameters: [
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        guard let accessToken else { throw RemoteFolderError.needsReauthentication }
        return accessToken
    }

    // MARK: - Internals

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func exchange(parameters: [String: String]) async throws {
        var body = parameters
        body["client_id"] = clientId

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteFolderError.offline }

        guard http.statusCode < 400 else {
            // A revoked or expired refresh token is permanent; clear it so the
            // UI can prompt for a fresh sign-in instead of retrying forever.
            if http.statusCode == 400 || http.statusCode == 401 { keychain.refreshToken = nil }
            throw RemoteFolderError.needsReauthentication
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = decoded.access_token
        accessTokenExpiry = Date().addingTimeInterval(decoded.expires_in)
        // Only sent on the first consent; a refresh response omits it.
        if let refresh = decoded.refresh_token { keychain.refreshToken = refresh }
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let scheme = String(redirectURI.split(separator: ":").first ?? "")
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: RemoteFolderError.needsReauthentication)
                }
            }
            session.presentationContextProvider = self
            // Use the shared cookie jar so someone already signed into Google in
            // Safari is not made to type their password again.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

extension GoogleAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The refresh token is a long-lived credential, so it belongs in the Keychain
/// rather than UserDefaults — and only unlocked on this device.
struct KeychainStore {
    let service: String

    var refreshToken: String? {
        get { read("refresh_token") }
        nonmutating set { write("refresh_token", newValue) }
    }

    private func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}
