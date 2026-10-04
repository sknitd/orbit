import Foundation
import XCTest
@testable import NotchOrbitPlus

final class SpotifyArtworkClientTests: XCTestCase, @unchecked Sendable {
    func testExplicitLoadStreamsActualBytesWithoutCredentialsOrStartupRequests() async throws {
        let body = Data([137, 80, 78, 71, 1, 2, 3, 4])
        let fixture = ArtworkHTTPFixture(response: .init(body: body))
        defer { fixture.close() }
        let client = PlusSpotifyArtworkClient(session: fixture.session)
        XCTAssertTrue(fixture.requests.isEmpty)
        let downloaded = try await client.load(fixture.url)
        XCTAssertEqual(downloaded, body)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 6)
    }

    func testDeclaredAndStreamingLimitsRejectBeforeImageDecode() async throws {
        for declared in [false, true] {
            let fixture = ArtworkHTTPFixture(response: .init(body: Data(repeating: 1,
                count: PlusSpotifyArtworkPolicy.maximumBytes + 1), includeLength: declared))
            defer { fixture.close() }
            do { _ = try await PlusSpotifyArtworkClient(session: fixture.session).load(fixture.url); XCTFail("Oversized artwork must fail") }
            catch { XCTAssertEqual(error as? PlusSpotifyArtworkError, .oversized) }
        }
    }

    func testFinalForeignOriginAndHTTPFailureRemainVisible() async throws {
        let foreign = ArtworkHTTPFixture(response: .init(body: Data([1]), responseURL: URL(string: "https://example.invalid/art")))
        defer { foreign.close() }
        do { _ = try await PlusSpotifyArtworkClient(session: foreign.session).load(foreign.url); XCTFail("Foreign final origin must fail") }
        catch { XCTAssertEqual(error as? PlusSpotifyArtworkError, .provider) }
        let failure = ArtworkHTTPFixture(response: .init(body: Data(), status: 403))
        defer { failure.close() }
        do { _ = try await PlusSpotifyArtworkClient(session: failure.session).load(failure.url); XCTFail("HTTP failure must fail") }
        catch { XCTAssertEqual(error as? PlusSpotifyArtworkError, .response(403)) }
    }

    func testNamedProviderPolicyRejectsLookalikesCredentialsAndUnsafeTransport() async throws {
        for raw in ["http://i.scdn.co/image/fixture", "https://i.scdn.co.evil.invalid/image/fixture",
                    "https://user:secret@i.scdn.co/image/fixture", "https://i.scdn.co:444/image/fixture",
                    "https://example.invalid/image/fixture", "https://i.scdn.co/image/fixture#fragment"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(PlusSpotifyArtworkPolicy.allows(url))
            do { _ = try await PlusSpotifyArtworkClient().load(url); XCTFail("Invalid provider must fail before a request") }
            catch { XCTAssertEqual(error as? PlusSpotifyArtworkError, .provider) }
        }
        XCTAssertTrue(PlusSpotifyArtworkPolicy.allows(try XCTUnwrap(URL(string: "https://i.scdn.co/image/fixture"))))
        XCTAssertTrue(PlusSpotifyArtworkPolicy.allows(try XCTUnwrap(URL(string: "https://image-cdn-ak.spotifycdn.com/image/fixture"))))
    }

    func testRedirectDelegateOnlyAllowsNamedHTTPSImageHosts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: "https://i.scdn.co/image/fixture"))
        let task = session.dataTask(with: original) // Deliberately never resumed.
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        let guardDelegate = PlusSpotifyArtworkRedirectGuard()
        for raw in ["https://image-cdn-ak.spotifycdn.com/image/fixture", "https://example.invalid/art"] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: raw)))
            let accepted: URLRequest? = await withCheckedContinuation { continuation in
                guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: request) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(accepted != nil, PlusSpotifyArtworkPolicy.allows(request.url!))
        }
    }
}

private struct ArtworkHTTPResponse: Sendable {
    var body: Data
    var status = 200
    var includeLength = true
    var responseURL: URL?
}

private final class ArtworkHTTPFixture: @unchecked Sendable {
    let session: URLSession
    let url = URL(string: "https://i.scdn.co/image/fixture-\(UUID().uuidString)")!
    init(response: ArtworkHTTPResponse) {
        ArtworkFixtureProtocol.registry.register(url, response: response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkFixtureProtocol.self]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }
    var requests: [URLRequest] { ArtworkFixtureProtocol.registry.requests(for: url) }
    func close() { session.invalidateAndCancel(); ArtworkFixtureProtocol.registry.remove(url) }
}

private final class ArtworkFixtureProtocol: URLProtocol {
    static let registry = ArtworkFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = Self.registry.response(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var headers = ["Content-Type": "image/png"]
        if response.includeLength { headers["Content-Length"] = String(response.body.count) }
        guard let http = HTTPURLResponse(url: response.responseURL ?? url, statusCode: response.status,
                                         httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: response.body.count, by: 8_191) {
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<min(offset + 8_191, response.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ArtworkFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: ArtworkHTTPResponse] = [:]
    private var recorded: [URL: [URLRequest]] = [:]
    func register(_ url: URL, response: ArtworkHTTPResponse) {
        lock.lock(); defer { lock.unlock() }; responses[url] = response; recorded[url] = []
    }
    func response(for request: URLRequest) -> ArtworkHTTPResponse? {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url else { return nil }
        recorded[url, default: []].append(request); return responses[url]
    }
    func requests(for url: URL) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded[url] ?? [] }
    func remove(_ url: URL) { lock.lock(); defer { lock.unlock() }; responses[url] = nil; recorded[url] = nil }
}
