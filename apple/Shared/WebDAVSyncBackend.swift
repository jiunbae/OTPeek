import Foundation
import os

struct WebDAVConfiguration: Codable, Sendable {
    let url: URL
    let username: String
    let password: String

    init(endpoint: String, username: String, password: String) throws {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              !username.contains(":") else {
            throw OtpError.Backend(msg: "Enter an HTTPS WebDAV URL and a username without a colon.")
        }
        let path = components.percentEncodedPath
        if !path.lowercased().hasSuffix(".otpvault") {
            components.percentEncodedPath = path + (path.hasSuffix("/") ? "" : "/") + "otpeek-vault.otpvault"
        }
        guard let url = components.url else {
            throw OtpError.Backend(msg: "The WebDAV URL is invalid.")
        }
        self.url = url
        self.username = username
        self.password = password
    }

    var authorization: String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

/// The synchronous UniFFI callback is invoked from the store's background queue.
final class WebDAVSyncBackend: SyncBackend, Sendable {
    private static let maximumVaultBytes = 16 * 1024 * 1024
    private let configuration: WebDAVConfiguration

    init(_ configuration: WebDAVConfiguration) {
        self.configuration = configuration
    }

    func fetch() throws -> RemoteBlob? {
        let response = try send(method: "GET")
        switch response.status {
        case 200: return RemoteBlob(data: response.data, etag: response.etag)
        case 404, 410: return nil
        default: throw Self.error(for: response.status)
        }
    }

    func store(data: Data, ifMatch: String?) throws -> String {
        guard data.count <= Self.maximumVaultBytes else {
            throw OtpError.Backend(msg: "The vault exceeds the 16 MiB WebDAV limit.")
        }
        let headers: [String: String]
        if let tag = ifMatch {
            let bytes = Array(tag.utf8)
            guard bytes.count >= 2, bytes.first == 34, bytes.last == 34,
                  bytes.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) || $0 >= 128 }) else {
                throw OtpError.Backend(msg: "The server must provide a strong WebDAV ETag.")
            }
            headers = ["If-Match": tag]
        } else {
            headers = ["If-None-Match": "*"]
        }
        let response = try send(method: "PUT", data: data, headers: headers)
        switch response.status {
        case 200, 201, 204: return response.etag ?? ""
        default: throw Self.error(for: response.status)
        }
    }

    private struct Response: Sendable {
        let status: Int
        let etag: String?
        let data: Data
    }

    private func send(method: String, data: Data? = nil, headers: [String: String] = [:]) throws -> Response {
        var request = URLRequest(url: configuration.url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue(configuration.authorization, forHTTPHeaderField: "Authorization")
        if data != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let outgoingRequest = request
        let result = OSAllocatedUnfairLock(initialState: Optional<Result<Response, Error>>.none)
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 15
            settings.timeoutIntervalForResource = 30
            settings.httpShouldSetCookies = false
            settings.httpCookieStorage = nil
            settings.urlCredentialStorage = nil
            let delegate = NoWebDAVRedirects()
            let session = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let (stream, rawResponse) = try await session.bytes(for: outgoingRequest, delegate: delegate)
                guard let response = rawResponse as? HTTPURLResponse else {
                    throw OtpError.Network(msg: "WebDAV returned an invalid response.")
                }
                var body = Data()
                if method == "GET", response.statusCode == 200 {
                    guard response.expectedContentLength <= Int64(Self.maximumVaultBytes) else {
                        throw OtpError.Backend(msg: "The server vault exceeds the 16 MiB WebDAV limit.")
                    }
                    for try await byte in stream {
                        guard body.count < Self.maximumVaultBytes else {
                            throw OtpError.Backend(msg: "The server vault exceeds the 16 MiB WebDAV limit.")
                        }
                        body.append(byte)
                    }
                }
                let received = Response(status: response.statusCode,
                                        etag: response.value(forHTTPHeaderField: "ETag"), data: body)
                result.withLock { $0 = .success(received) }
            } catch {
                result.withLock {
                    $0 = .failure((error as? OtpError) ?? OtpError.Network(msg: "Unable to reach the HTTPS WebDAV endpoint."))
                }
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 35) == .success else {
            task.cancel()
            throw OtpError.Network(msg: "The WebDAV request timed out.")
        }
        guard let response = result.withLock({ $0 }) else {
            throw OtpError.Network(msg: "WebDAV returned no response.")
        }
        return try response.get()
    }

    private static func error(for status: Int) -> OtpError {
        switch status {
        case 401, 403: return .Auth(msg: "Check your WebDAV credentials and permissions.")
        case 412: return .Conflict
        case 300...399: return .Backend(msg: "Enter the final HTTPS URL instead of a WebDAV redirect.")
        default: return .Backend(msg: "WebDAV returned HTTP \(status).")
        }
    }
}

private final class NoWebDAVRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
