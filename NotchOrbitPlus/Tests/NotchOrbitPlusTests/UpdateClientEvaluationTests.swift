import CryptoKit
import Foundation
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbitPlus

/// All requests are intercepted. These are HTTP transport fixtures, not live update-channel checks.
final class UpdateClientEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    func testFetchAndStreamedZIPVerifyBytesProgressAndSavedProvenance() async throws {
        let archive = storedZIP(payload: Data((0..<196_608).map { UInt8(truncatingIfNeeded: $0) }))
        let source = fixtureDirectory.appendingPathComponent("original.zip")
        try archive.write(to: source)
        let inventory = try ZIPInspector.inspect(source)
        XCTAssertEqual(inventory.entryCount, 1)
        XCTAssertEqual(inventory.expandedBytes, 196_608)
        let manifest = try feedData(archive: archive)
        let feed = try CoreUpdateFeed.decode(manifest)
        let fixture = UpdateHTTPFixture(routes: [
            CoreUpdateFeed.channelURL: .init(body: manifest),
            feed.archiveURL: .init(body: archive, chunkSize: 7_919)
        ])
        defer { fixture.close() }
        let client = PlusUpdateClient(session: fixture.session)
        let fetched = try await client.fetchFeed()
        XCTAssertEqual(fetched, feed)
        let progress = UpdateProgressRecorder()
        let output = try await client.download(fetched) { progress.append($0) }
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: output), archive)
        XCTAssertEqual(try Data(contentsOf: source), archive)
        let verification = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            output.deletingLastPathComponent().appendingPathComponent("download-verification.json"))) as? [String: Any])
        XCTAssertEqual(Set(verification.keys), ["version", "sourceCommit", "sha256", "bytes"])
        XCTAssertEqual(verification["version"] as? String, feed.version)
        XCTAssertEqual(verification["sourceCommit"] as? String, feed.sourceCommit)
        XCTAssertEqual(verification["sha256"] as? String, feed.archiveSHA256)
        XCTAssertEqual(verification["bytes"] as? Int, archive.count)
        let values = progress.values
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 1 }, "Exercise the 64 KiB streaming flush path")
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(fixture.requests.count, 2)
        for request in fixture.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "NotchOrbitPlus-update/0.2")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }

    func testWrongChecksumAndTruncatedStreamRemoveOnlyTheirPartialDownloads() async throws {
        let archive = storedZIP(payload: Data(repeating: 0x5a, count: 150_000))
        let feed = try CoreUpdateFeed.decode(feedData(archive: archive))
        var tampered = archive
        tampered[100] ^= 1
        for body in [tampered, Data(archive.dropLast())] {
            let fixture = UpdateHTTPFixture(routes: [feed.archiveURL: .init(body: body, includeLength: false)])
            defer { fixture.close() }
            try await withPreservedCache { client in
                do {
                    _ = try await client.download(feed) { _ in }
                    XCTFail("Changed bytes or incomplete size must reject the download")
                } catch let failure as CoreUpdateError {
                    XCTAssertEqual(failure, .invalidChecksum)
                }
            } client: { PlusUpdateClient(session: fixture.session) }
        }
    }

    func testDeclaredAndStreamedOversizeAreRejectedWithoutLeavingCacheFiles() async throws {
        let archive = storedZIP(payload: Data(repeating: 0x31, count: 150_000))
        let feed = try CoreUpdateFeed.decode(feedData(archive: archive))
        let responses: [UpdateHTTPResponse] = [
            .init(body: archive, contentLength: archive.count + 1),
            .init(body: archive + Data([0]), includeLength: false)
        ]
        for response in responses {
            let fixture = UpdateHTTPFixture(routes: [feed.archiveURL: response])
            defer { fixture.close() }
            try await withPreservedCache { client in
                do {
                    _ = try await client.download(feed) { _ in }
                    XCTFail("Both declared and streamed excess bytes must reject")
                } catch let failure as PlusUpdateNetworkError {
                    guard case .oversized = failure else { return XCTFail("Unexpected error: \(failure)") }
                }
            } client: { PlusUpdateClient(session: fixture.session) }
        }
        let fixture = UpdateHTTPFixture(routes: [CoreUpdateFeed.channelURL:
            .init(body: Data(repeating: 0x20, count: 128 * 1_024 + 1), includeLength: false)])
        defer { fixture.close() }
        do {
            _ = try await PlusUpdateClient(session: fixture.session).fetchFeed()
            XCTFail("The feed itself must also be bounded while streaming")
        } catch let failure as PlusUpdateNetworkError {
            guard case .oversized = failure else { return XCTFail("Unexpected feed error: \(failure)") }
        }
    }

    func testUnexpectedFinalURLAndHTTPFailuresRejectBeforePublication() async throws {
        let archive = storedZIP(payload: Data("safe original".utf8))
        let feed = try CoreUpdateFeed.decode(feedData(archive: archive))
        let source = fixtureDirectory.appendingPathComponent("keep.zip")
        try archive.write(to: source)
        let responses: [(UpdateHTTPResponse, Int?)] = [
            (.init(body: archive, responseURL: URL(string: "https://example.invalid/replaced.zip")!), nil),
            (.init(body: Data(), status: 404), 404),
            (.init(body: Data(), status: 503), 503),
            (.init(body: Data(), status: 302), 302)
        ]
        for (response, status) in responses {
            let fixture = UpdateHTTPFixture(routes: [feed.archiveURL: response])
            defer { fixture.close() }
            try await withPreservedCache { client in
                do {
                    _ = try await client.download(feed) { _ in }
                    XCTFail("An unexpected URL or HTTP status must not publish an archive")
                } catch let failure as PlusUpdateNetworkError {
                    switch (failure, status) {
                    case (.redirect, nil), (.unpublished, 404): break
                    case (.response(let actual), .some(let expected)): XCTAssertEqual(actual, expected)
                    default: XCTFail("Unexpected failure: \(failure)")
                    }
                }
            } client: { PlusUpdateClient(session: fixture.session) }
        }
        XCTAssertEqual(try Data(contentsOf: source), archive)
    }

    private func withPreservedCache(_ operation: (PlusUpdateClient) async throws -> Void,
                                    client: () -> PlusUpdateClient) async throws {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("com.sknitd.NotchOrbitPlus/Updates", isDirectory: true)
        let existing = cache.appendingPathComponent("evaluation-existing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }
        let marker = existing.appendingPathComponent("preserve.bin")
        let markerData = Data("Preexisting cache belongs to a different download.".utf8)
        try markerData.write(to: marker)
        let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        try await operation(client())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)), namesBefore,
                       "A rejected download must remove its own UUID directory")
        XCTAssertEqual(try Data(contentsOf: marker), markerData)
    }

    private func feedData(archive: Data) throws -> Data {
        let source = String(repeating: "b", count: 40)
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "product": "NotchOrbitPlus", "bundle_identifier": "com.sknitd.NotchOrbitPlus",
            "version": "9.9.9", "minimum_macos": "14.0", "source_commit": source,
            "archive_url": "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/packages/9.9.9/\(source)/NotchOrbitPlus.app.zip",
            "archive_sha256": SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
            "archive_bytes": archive.count,
            "release_notes_url": "https://github.com/sknitd/orbit/tree/\(source)/NotchOrbitPlus",
            "published_at": "2026-10-04T00:00:00Z", "signing": ["kind": "adhoc", "notarized": false]
        ])
    }

    /// An independently constructed, uncompressed classic ZIP exercises several streaming flushes.
    private func storedZIP(payload: Data) -> Data {
        let name = Data("NotchOrbitPlus.app/Contents/fixture.bin".utf8)
        var crc: UInt32 = 0xffff_ffff
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0) }
        }
        crc ^= 0xffff_ffff
        var result = Data()
        func append(_ value: UInt32, bytes: Int) {
            for index in 0..<bytes { result.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        append(0x0403_4b50, bytes: 4); append(20, bytes: 2)
        for _ in 0..<4 { append(0, bytes: 2) }
        append(crc, bytes: 4); append(UInt32(payload.count), bytes: 4); append(UInt32(payload.count), bytes: 4)
        append(UInt32(name.count), bytes: 2); append(0, bytes: 2); result.append(name); result.append(payload)
        let directoryOffset = result.count
        append(0x0201_4b50, bytes: 4); append(20, bytes: 2); append(20, bytes: 2)
        for _ in 0..<4 { append(0, bytes: 2) }
        append(crc, bytes: 4); append(UInt32(payload.count), bytes: 4); append(UInt32(payload.count), bytes: 4)
        append(UInt32(name.count), bytes: 2)
        for _ in 0..<4 { append(0, bytes: 2) }
        append(0, bytes: 4); append(0, bytes: 4); result.append(name)
        let directoryLength = result.count - directoryOffset
        append(0x0605_4b50, bytes: 4); append(0, bytes: 2); append(0, bytes: 2)
        append(1, bytes: 2); append(1, bytes: 2)
        append(UInt32(directoryLength), bytes: 4); append(UInt32(directoryOffset), bytes: 4); append(0, bytes: 2)
        return result
    }
}

private struct UpdateHTTPResponse: Sendable {
    var body: Data
    var status = 200
    var responseURL: URL?
    var contentLength: Int?
    var includeLength = true
    var chunkSize = 8_192
}

private final class UpdateHTTPFixture: @unchecked Sendable {
    let session: URLSession
    private let protocolType: UpdateFixtureProtocol.Type
    init(routes: [URL: UpdateHTTPResponse]) {
        protocolType = UpdateFixtureProtocol.registry.reserve(routes: routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolType]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }
    var requests: [URLRequest] { UpdateFixtureProtocol.registry.requests(protocolType: protocolType) }
    func close() {
        session.invalidateAndCancel()
        UpdateFixtureProtocol.registry.remove(protocolType: protocolType)
    }
}

private class UpdateFixtureProtocol: URLProtocol {
    static let registry = UpdateFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.registry.response(for: request, protocolType: type(of: self)), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if response.includeLength { headers["Content-Length"] = String(response.contentLength ?? response.body.count) }
        guard let http = HTTPURLResponse(url: response.responseURL ?? url, statusCode: response.status,
                                         httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: response.body.count, by: response.chunkSize) {
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<min(offset + response.chunkSize, response.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// A separate registered class isolates each session even when XCTest executes cases concurrently.
// No header propagation or shared last-request handler is required for routing.
private final class UpdateFixtureProtocolA: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolB: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolC: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolD: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolE: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolF: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolG: UpdateFixtureProtocol {}
private final class UpdateFixtureProtocolH: UpdateFixtureProtocol {}

private final class UpdateFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let available: [UpdateFixtureProtocol.Type] = [UpdateFixtureProtocolA.self, UpdateFixtureProtocolB.self,
        UpdateFixtureProtocolC.self, UpdateFixtureProtocolD.self, UpdateFixtureProtocolE.self,
        UpdateFixtureProtocolF.self, UpdateFixtureProtocolG.self, UpdateFixtureProtocolH.self]
    private var routes: [ObjectIdentifier: [URL: UpdateHTTPResponse]] = [:]
    private var recorded: [ObjectIdentifier: [URLRequest]] = [:]
    func reserve(routes: [URL: UpdateHTTPResponse]) -> UpdateFixtureProtocol.Type {
        lock.lock(); defer { lock.unlock() }
        guard let type = available.first(where: { self.routes[ObjectIdentifier($0)] == nil }) else {
            preconditionFailure("More than eight update fixture sessions were opened without closing them")
        }
        let key = ObjectIdentifier(type)
        self.routes[key] = routes; recorded[key] = []
        return type
    }
    func response(for request: URLRequest, protocolType: UpdateFixtureProtocol.Type) -> UpdateHTTPResponse? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(protocolType)
        guard let url = request.url else { return nil }
        recorded[key, default: []].append(request)
        return routes[key]?[url]
    }
    func requests(protocolType: UpdateFixtureProtocol.Type) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded[ObjectIdentifier(protocolType)] ?? []
    }
    func remove(protocolType: UpdateFixtureProtocol.Type) {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(protocolType)
        routes[key] = nil; recorded[key] = nil
    }
}

private final class UpdateProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}
