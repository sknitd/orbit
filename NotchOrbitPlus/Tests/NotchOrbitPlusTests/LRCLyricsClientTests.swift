import Foundation
import XCTest
import NotchCore
@testable import NotchOrbitPlus

/// HTTP fixtures only: these tests never contact LRCLIB or claim a live-service result.
final class LRCLyricsClientTests: XCTestCase, @unchecked Sendable {
    func testLookupStreamsMatchingLyricsAndSendsOnlyPublicMetadata() async throws {
        let query = makeQuery("HTTP Fixture A+B & Café")
        let fixture = try LyricsHTTPFixture(query: query, response: .init(body: response(for: query)))
        defer { fixture.close() }
        XCTAssertTrue(fixture.requests.isEmpty, "Client construction must not contact the service")
        let client = PlusLRCLyricsClient(session: fixture.session)
        XCTAssertTrue(fixture.requests.isEmpty)
        let result = try await client.lookup(query)
        XCTAssertEqual(result.kind, .synced)
        XCTAssertEqual(result.lines.map(\.time), [2.25, 4])
        XCTAssertEqual(result.lines.map(\.text), ["Fixture first line", "Fixture second line"])
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(request.url, try query.requestURL())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testNotFoundAndRateLimitDoNotRetryOrSearch() async throws {
        for status in [404, 429] {
            let query = makeQuery("HTTP Fixture status \(status)")
            let fixture = try LyricsHTTPFixture(query: query, response: .init(body: Data(), status: status))
            defer { fixture.close() }
            do {
                _ = try await PlusLRCLyricsClient(session: fixture.session).lookup(query)
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? PlusLRCLyricsNetworkError, status == 404 ? .notFound : .rateLimited)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testStreamedResponseWithoutLengthStopsAtSizeLimit() async throws {
        let query = makeQuery("HTTP Fixture oversized")
        let fixture = try LyricsHTTPFixture(query: query,
            response: .init(body: Data(repeating: 32, count: CoreLyricsResult.maximumResponseBytes + 1), includeLength: false))
        defer { fixture.close() }
        do {
            _ = try await PlusLRCLyricsClient(session: fixture.session).lookup(query)
            XCTFail("Oversized stream must fail")
        } catch { XCTAssertEqual(error as? PlusLRCLyricsNetworkError, .oversized) }
    }

    func testChangedResponseOriginIsRejected() async throws {
        let query = makeQuery("HTTP Fixture redirect")
        let fixture = try LyricsHTTPFixture(query: query,
            response: .init(body: response(for: query), responseURL: URL(string: "https://example.invalid/api/get")))
        defer { fixture.close() }
        do {
            _ = try await PlusLRCLyricsClient(session: fixture.session).lookup(query)
            XCTFail("Changed response URL must fail")
        } catch { XCTAssertEqual(error as? PlusLRCLyricsNetworkError, .redirect) }
    }

    private func makeQuery(_ title: String) -> CoreLyricsQuery {
        CoreLyricsQuery(title: title, artist: "HTTP Fixture Artist", album: "HTTP Fixture Album", duration: 180)
    }

    private func response(for query: CoreLyricsQuery) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": 456, "trackName": query.title,
            "artistName": query.artist, "albumName": query.album, "duration": query.duration,
            "instrumental": false, "plainLyrics": "Fixture first line\nFixture second line",
            "syncedLyrics": "[00:02.25]Fixture first line\n[00:04.00]Fixture second line"])
    }
}

private struct LyricsHTTPResponse: Sendable {
    var body: Data
    var status = 200
    var includeLength = true
    var responseURL: URL?
}

private final class LyricsHTTPFixture: @unchecked Sendable {
    let session: URLSession
    private let url: URL
    init(query: CoreLyricsQuery, response: LyricsHTTPResponse) throws {
        url = try query.requestURL()
        LyricsFixtureProtocol.registry.register(url, response: response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsFixtureProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }
    var requests: [URLRequest] { LyricsFixtureProtocol.registry.requests(for: url) }
    func close() {
        session.invalidateAndCancel()
        LyricsFixtureProtocol.registry.remove(url)
    }
}

private final class LyricsFixtureProtocol: URLProtocol {
    static let registry = LyricsFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = Self.registry.response(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var headers = ["Content-Type": "application/json"]
        if response.includeLength { headers["Content-Length"] = String(response.body.count) }
        guard let http = HTTPURLResponse(url: response.responseURL ?? url, statusCode: response.status,
                                         httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: response.body.count, by: 3_113) {
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<min(offset + 3_113, response.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Each test has distinct metadata URLs; the lock isolates fixtures under concurrent XCTest runs.
private final class LyricsFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: LyricsHTTPResponse] = [:]
    private var recorded: [URL: [URLRequest]] = [:]
    func register(_ url: URL, response: LyricsHTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        precondition(responses[url] == nil, "Lyrics fixture metadata URLs must be unique")
        responses[url] = response; recorded[url] = []
    }
    func response(for request: URLRequest) -> LyricsHTTPResponse? {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url else { return nil }
        recorded[url, default: []].append(request)
        return responses[url]
    }
    func requests(for url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded[url] ?? []
    }
    func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }; responses[url] = nil; recorded[url] = nil
    }
}
