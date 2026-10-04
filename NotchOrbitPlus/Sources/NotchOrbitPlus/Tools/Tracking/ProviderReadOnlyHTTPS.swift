import Foundation
import NotchCore

private final class ProviderRejectRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ProviderReadOnlyHTTPS {
    typealias Loader = @Sendable (URLRequest) async throws -> Data
    static func url(host: String, path: String, query: [URLQueryItem]) throws -> URL {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = path; parts.queryItems = query
        guard let url = parts.url, allowed(url) else { throw OnlineServiceError.message("Refused an unapproved provider URL.") }
        return url
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        switch url.host {
        case "api.aftership.com": return url.path == "/tracking/\(AfterShipTrackingData.version)/trackings"
        case "api.aviationstack.com": return url.path == "/v1/flights"
        case "v3.football.api-sports.io": return ["/teams", "/fixtures"].contains(url.path)
        case "air-quality-api.open-meteo.com": return url.path == "/v1/air-quality"
        case "api.open-meteo.com": return url.path == "/v1/forecast"
        default: return false
        }
    }
    static func request(_ url: URL, key: String? = nil, header: String? = nil) throws -> URLRequest {
        guard allowed(url) else { throw OnlineServiceError.message("Refused an unapproved provider URL.") }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key {
            guard !key.isEmpty, key.utf8.count <= 8_192, !key.contains("\n"), !key.contains("\r") else { throw OnlineServiceError.message("Enter a valid provider key.") }
            if let header {
                guard (url.host == "api.aftership.com" && header == "as-api-key") ||
                        (url.host == "v3.football.api-sports.io" && header == "x-apisports-key") else { throw OnlineServiceError.message("Credential header does not match its provider.") }
                request.setValue(key, forHTTPHeaderField: header)
            }
        }
        return request
    }
    static func load(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, allowed(url), request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil else {
            throw OnlineServiceError.message("Provider tools accept approved read-only GET requests only.")
        }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: ProviderRejectRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw OnlineServiceError.message("Provider request failed (HTTP \(code)). Check your key, plan access and rate limit.")
            }
            guard response.expectedContentLength <= 4 * 1_024 * 1_024 else { throw OnlineServiceError.message("Provider response exceeds 4 MB.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4 * 1_024 * 1_024 else { throw OnlineServiceError.message("Provider response exceeds 4 MB.") }
                data.append(byte)
            }
            try Task.checkCancellation(); return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as OnlineServiceError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw OnlineServiceError.message("The provider could not be reached. Check your connection and retry.")
        }
    }
}
