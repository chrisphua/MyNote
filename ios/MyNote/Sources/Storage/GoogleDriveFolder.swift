import Foundation
import MyNoteCore

/// Backup into a "MyNote" folder in the user's Google Drive.
///
/// The cross-platform option: the same folder is readable by the Android app, so
/// a note written on an iPhone shows up on an Android tablet. iCloud Drive
/// cannot do this — Apple publishes no Android API for it.
actor GoogleDriveFolder: RemoteFolder {
    nonisolated let displayName = "Google Drive"

    private static let folderName = "MyNote"
    private static let folderMime = "application/vnd.google-apps.folder"
    private static let api = "https://www.googleapis.com/drive/v3"
    private static let upload = "https://www.googleapis.com/upload/drive/v3"

    private let auth: GoogleAuth
    private var folderId: String?
    /// Drive addresses files by opaque id, not by name, so every operation needs
    /// the name→id mapping the last listing produced.
    private var fileIds: [String: String] = [:]

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    // MARK: - RemoteFolder

    func list() async throws -> [RemoteFile] {
        let folder = try await folder()
        var items: [RemoteFile] = []
        var pageToken: String?

        repeat {
            var query = [
                URLQueryItem(name: "q", value: "'\(folder)' in parents and trashed=false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime,size,version)"),
                URLQueryItem(name: "pageSize", value: "200"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }

            let listing: FileList = try await get("\(Self.api)/files", query: query)
            for file in listing.files {
                fileIds[file.name] = file.id
                items.append(RemoteFile(
                    name: file.name,
                    modifiedAt: ISO8601DateFormatter().date(from: file.modifiedTime ?? "") ?? .distantPast,
                    size: Int(file.size ?? "0") ?? 0,
                    // Drive bumps `version` on every content or metadata change,
                    // which is exactly the "has this changed" signal we need.
                    version: file.version ?? file.modifiedTime ?? "0"
                ))
            }
            pageToken = listing.nextPageToken
        } while pageToken != nil

        return items
    }

    func read(_ name: String) async throws -> Data {
        guard let id = try await id(for: name) else {
            throw RemoteFolderError.notFound(name)
        }
        return try await request(
            URLRequest(url: URL(string: "\(Self.api)/files/\(id)?alt=media")!)
        )
    }

    func write(_ name: String, data: Data) async throws {
        let token = try await auth.token()

        if let id = try await id(for: name) {
            // Existing file: replace its contents, keeping the same id so other
            // devices' bookmarks and the Drive revision history stay intact.
            var request = URLRequest(url: URL(string: "\(Self.upload)/files/\(id)?uploadType=media")!)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            _ = try await send(request)
            return
        }

        // New file: metadata and content in one multipart request.
        let folder = try await folder()
        let boundary = "mynote-\(UUID().uuidString)"
        let metadata = try JSONEncoder().encode(NewFile(name: name, parents: [folder]))

        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "\(Self.upload)/files?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let created = try JSONDecoder().decode(DriveFile.self, from: try await send(request))
        fileIds[name] = created.id
    }

    func delete(_ name: String) async throws {
        guard let id = try await id(for: name) else { return }
        var request = URLRequest(url: URL(string: "\(Self.api)/files/\(id)")!)
        request.httpMethod = "DELETE"
        _ = try await send(request, authorize: true)
        fileIds.removeValue(forKey: name)
    }

    // MARK: - Folder resolution

    /// Find the MyNote folder, creating it on first use.
    private func folder() async throws -> String {
        if let folderId { return folderId }

        let query = [
            URLQueryItem(
                name: "q",
                value: "mimeType='\(Self.folderMime)' and name='\(Self.folderName)' and trashed=false"
            ),
            URLQueryItem(name: "fields", value: "files(id,name)"),
        ]
        let existing: FileList = try await get("\(Self.api)/files", query: query)
        if let found = existing.files.first {
            folderId = found.id
            return found.id
        }

        var request = URLRequest(url: URL(string: "\(Self.api)/files?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            NewFile(name: Self.folderName, parents: nil, mimeType: Self.folderMime)
        )
        let created = try JSONDecoder().decode(DriveFile.self, from: try await send(request, authorize: true))
        folderId = created.id
        return created.id
    }

    private func id(for name: String) async throws -> String? {
        if let cached = fileIds[name] { return cached }
        _ = try await list()
        return fileIds[name]
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: path)!
        components.queryItems = query
        let data = try await request(URLRequest(url: components.url!))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request(_ base: URLRequest) async throws -> Data {
        try await send(base, authorize: true)
    }

    private func send(_ base: URLRequest, authorize: Bool = false) async throws -> Data {
        var request = base
        if authorize || request.value(forHTTPHeaderField: "Authorization") == nil {
            request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteFolderError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw RemoteFolderError.offline }
        guard http.statusCode < 400 else { throw Self.error(status: http.statusCode, body: data) }
        return data
    }

    private static func error(status: Int, body: Data) -> RemoteFolderError {
        let message = (try? JSONDecoder().decode(DriveError.self, from: body))?.error.message ?? "Drive error"
        switch status {
        case 401, 403 where message.localizedCaseInsensitiveContains("insufficient"):
            return .needsReauthentication
        case 403 where message.localizedCaseInsensitiveContains("quota"):
            return .storageFull
        case 404:
            return .notFound(message)
        case 429, 500...599:
            // Rate limited or Drive is unwell; both are worth retrying later.
            return .offline
        default:
            return .provider(message)
        }
    }

    // MARK: - Wire types

    private struct FileList: Decodable {
        let files: [DriveFile]
        let nextPageToken: String?
    }

    private struct DriveFile: Decodable {
        let id: String
        let name: String
        let modifiedTime: String?
        let size: String?
        let version: String?
    }

    private struct NewFile: Encodable {
        let name: String
        let parents: [String]?
        var mimeType: String?
    }

    private struct DriveError: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}
