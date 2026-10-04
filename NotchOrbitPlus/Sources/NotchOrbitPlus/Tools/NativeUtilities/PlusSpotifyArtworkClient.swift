import Foundation

enum PlusSpotifyArtworkError: LocalizedError, Sendable, Equatable {
    case provider, response(Int), oversized
    var errorDescription: String? {
        switch self {
        case .provider: "Spotify artwork must use a supported Spotify HTTPS image host."
        case .response(let status): "Spotify artwork returned HTTP \(status)."
        case .oversized: "Spotify artwork exceeded the 4 MB download limit."
        }
    }
}

protocol PlusArtworkLoading: Sendable {
    func load(_ url: URL) async throws -> Data
}

enum PlusSpotifyArtworkPolicy {
    static let maximumBytes = 4 * 1_024 * 1_024
    private static let hosts: Set<String> = ["i.scdn.co", "mosaic.scdn.co", "lineup-images.scdn.co",
        "image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com"]
    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && hosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) && url.fragment == nil
    }
}

final class PlusSpotifyArtworkRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PlusSpotifyArtworkPolicy.allows(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

/// This client has no startup request or scheduler. Now Playing calls it only
/// for artwork supplied by the Spotify source after an explicit Connect.
struct PlusSpotifyArtworkClient: PlusArtworkLoading {
    private let injectedSession: URLSession?
    init(session: URLSession? = nil) { injectedSession = session }
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: PlusSpotifyArtworkRedirectGuard(), delegateQueue: nil)
    }
    func load(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        guard PlusSpotifyArtworkPolicy.allows(url) else { throw PlusSpotifyArtworkError.provider }
        let session = injectedSession ?? Self.makeSession()
        // A production session serves one artwork request. Ending, rejecting,
        // or cancelling the stream also cancels its underlying download.
        defer { if injectedSession == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlusSpotifyArtworkError.response(0) }
        guard let finalURL = http.url, PlusSpotifyArtworkPolicy.allows(finalURL) else { throw PlusSpotifyArtworkError.provider }
        guard http.statusCode == 200 else { throw PlusSpotifyArtworkError.response(http.statusCode) }
        let limit = PlusSpotifyArtworkPolicy.maximumBytes
        guard response.expectedContentLength < 0 || response.expectedContentLength <= limit else { throw PlusSpotifyArtworkError.oversized }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limit))
        for try await byte in bytes {
            guard data.count < limit else { throw PlusSpotifyArtworkError.oversized }
            data.append(byte)
            if data.count % 4_096 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }
}
