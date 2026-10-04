import Foundation
import NotchCore

enum PlusLRCLyricsNetworkError: LocalizedError, Sendable, Equatable {
    case notFound, rateLimited, response(Int), redirect, oversized

    var errorDescription: String? {
        switch self {
        case .notFound: "LRCLIB did not find lyrics for this song."
        case .rateLimited: "LRCLIB is limiting requests. Try again later."
        case .response(let status): "LRCLIB returned HTTP \(status). Try again later."
        case .redirect: "The lyrics request redirected outside its exact LRCLIB lookup URL."
        case .oversized: "The lyrics response exceeded the 2 MB limit."
        }
    }
}

private final class PlusLRCLyricsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// No scheduler, credentials, implicit fallback, or startup requests. The caller owns explicit consent.
protocol PlusLyricsLookupClient: Sendable {
    func lookup(_ query: CoreLyricsQuery) async throws -> CoreLyricsResult
}

struct PlusLRCLyricsClient: PlusLyricsLookupClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration, delegate: PlusLRCLyricsRedirectGuard(), delegateQueue: nil)
    }

    func lookup(_ query: CoreLyricsQuery) async throws -> CoreLyricsResult {
        try Task.checkCancellation()
        let url = try query.requestURL()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NotchOrbitPlus/0.3 (https://github.com/sknitd/orbit)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlusLRCLyricsNetworkError.response(0) }
        guard http.url?.absoluteString == url.absoluteString else { throw PlusLRCLyricsNetworkError.redirect }
        if http.statusCode == 404 { throw PlusLRCLyricsNetworkError.notFound }
        if http.statusCode == 429 { throw PlusLRCLyricsNetworkError.rateLimited }
        guard http.statusCode == 200 else { throw PlusLRCLyricsNetworkError.response(http.statusCode) }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= CoreLyricsResult.maximumResponseBytes else {
            throw PlusLRCLyricsNetworkError.oversized
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), CoreLyricsResult.maximumResponseBytes))
        for try await byte in bytes {
            guard data.count < CoreLyricsResult.maximumResponseBytes else { throw PlusLRCLyricsNetworkError.oversized }
            data.append(byte)
            if data.count % 4_096 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return try CoreLyricsResult.decode(data, for: query)
    }
}
