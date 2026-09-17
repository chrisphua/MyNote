import Foundation

public enum APIError: Error, Equatable, Sendable {
    case unauthenticated
    /// The account has no active `cloud_sync` entitlement — show the paywall.
    case subscriptionRequired
    case quotaExceeded(message: String)
    case conflict(message: String)
    case server(status: Int, code: String, message: String)
    case offline
    case decoding(String)
}

public struct Entitlement: Codable, Equatable, Sendable {
    public var entitlement: String
    public var active: Bool
    public var status: String
    public var expiresAt: Int64?
    public var productId: String
    public var platform: String
}

public struct EntitlementsResponse: Codable, Sendable {
    public var entitlements: [Entitlement]
}

/// The subset of the API the sync engine depends on. Extracted so the engine
/// can be driven by a scripted fake in tests instead of a live Worker.
public protocol SyncAPI: Sendable {
    func sync(cursor: Int, changes: [Change], limit: Int?) async throws -> SyncResponse
}

/// Talks to the Cloudflare Worker. The Firebase ID token is fetched lazily per
/// request so a refreshed token is picked up without recreating the client.
public actor APIClient: SyncAPI {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String?

    public init(baseURL: URL,
                session: URLSession = .shared,
                tokenProvider: @escaping @Sendable () async throws -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func sync(cursor: Int, changes: [Change], limit: Int? = nil) async throws -> SyncResponse {
        try await post("/v1/sync", body: SyncRequest(cursor: cursor, changes: changes, limit: limit))
    }

    public func entitlements() async throws -> [Entitlement] {
        let res: EntitlementsResponse = try await get("/v1/entitlements")
        return res.entitlements
    }

    public func verifyAppleTransaction(id: String) async throws -> [Entitlement] {
        struct Body: Codable { let transactionId: String }
        let res: EntitlementsResponse = try await post("/v1/iap/apple/verify", body: Body(transactionId: id))
        return res.entitlements
    }

    // MARK: - Transport

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(request(path, method: "GET"))
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var req = request(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req)
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        // Sync must never block the UI; a stalled network is just "try later".
        req.timeoutInterval = 30
        return req
    }

    private func send<Response: Decodable>(_ base: URLRequest) async throws -> Response {
        var req = base
        guard let token = try await tokenProvider() else { throw APIError.unauthenticated }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.decoding("not an HTTP response")
        }

        if http.statusCode >= 400 {
            throw Self.mapError(status: http.statusCode, data: data)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    struct ErrorBody: Decodable { let error: String?; let code: String? }

    static func mapError(status: Int, data: Data) -> APIError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.code ?? "error"
        let message = body?.error ?? "request failed"

        switch (status, code) {
        case (401, _):               return .unauthenticated
        case (402, _):               return .subscriptionRequired
        case (507, _):               return .quotaExceeded(message: message)
        case (409, _):               return .conflict(message: message)
        default:                     return .server(status: status, code: code, message: message)
        }
    }
}
