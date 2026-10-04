import Foundation
import XCTest
@testable import NotchOrbitPlus

private actor GithubFixtureServer {
    var requests: [URLRequest] = []
    let fillPages: Bool
    init(fillPages: Bool = false) { self.fillPages = fillPages }
    func load(_ request: URLRequest) throws -> Data {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = Int(query.first(where: { $0.name == "page" })?.value ?? "") ?? 1
        if url.path == "/user/repos" {
            let count = fillPages ? 50 : 1
            let rows = (0..<count).map { index -> [String: Any] in
                let id = (page - 1) * 50 + index + 1
                return ["id": id, "full_name": "owner/repo-\(id)", "html_url": "https://github.com/owner/repo-\(id)", "private": true]
            }
            return try JSONSerialization.data(withJSONObject: rows)
        }
        let count = fillPages ? 50 : 2
        var rows: [[String: Any]] = []
        for index in 0..<count {
            let id = (page - 1) * 50 + index + 1
            var row: [String: Any] = [:]
            row["id"] = id
            row["display_title"] = "Build fixture \(index)"
            row["head_branch"] = "main"
            row["status"] = index == 0 ? "completed" : "in_progress"
            row["conclusion"] = index == 0 ? ("success" as Any) : (NSNull() as Any)
            row["updated_at"] = "2026-10-08T12:00:00Z"
            row["html_url"] = "https://github.com/owner/repo-1/actions/runs/\(id)"
            rows.append(row)
        }
        return try JSONSerialization.data(withJSONObject: ["total_count": fillPages ? 400 : 2, "workflow_runs": rows])
    }
    func recorded() -> [URLRequest] { requests }
}

final class GithubActionsClientTests: XCTestCase, @unchecked Sendable {
    func testOwnedRepositoriesAndRealRunFieldsUseOnlyExplicitAuthenticatedGETs() async throws {
        let fixture = GithubFixtureServer()
        let client = GithubActionsClient(load: { try await fixture.load($0) })
        let initialRequests = await fixture.recorded()
        XCTAssertTrue(initialRequests.isEmpty)
        let repositories = try await client.repositories(token: "fixture-token")
        XCTAssertEqual(repositories.items.count, 1); XCTAssertFalse(repositories.limited)
        let runs = try await client.runs(repository: "owner/repo-1", token: "fixture-token")
        XCTAssertEqual(runs.items.count, 2); XCTAssertEqual(runs.total, 2)
        XCTAssertEqual(runs.items.first?.conclusion, "success")
        XCTAssertEqual(runs.items.last?.status, "in_progress")
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        }
        let query = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "type" })?.value, "owner")
    }

    func testFullPagesStopAtRepositoryAndRunCapsAndExposeIncompleteCoverage() async throws {
        let fixture = GithubFixtureServer(fillPages: true)
        let client = GithubActionsClient(load: { try await fixture.load($0) })
        let repositories = try await client.repositories(token: "fixture-token")
        XCTAssertEqual(repositories.items.count, 250); XCTAssertTrue(repositories.limited)
        let runs = try await client.runs(repository: "owner/repo-1", token: "fixture-token")
        XCTAssertEqual(runs.items.count, 150); XCTAssertEqual(runs.total, 400)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.filter { $0.url?.path == "/user/repos" }.count, 5)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/actions/runs") == true }.count, 3)
    }

    @MainActor
    func testPrecancelledClientDoesNotReachInjectedTransport() async {
        let fixture = GithubFixtureServer()
        let client = GithubActionsClient(load: { try await fixture.load($0) })
        let task = Task { try await client.repositories(token: "fixture-token") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled requests must not succeed") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation: \(error.localizedDescription)") }
        let requests = await fixture.recorded()
        XCTAssertTrue(requests.isEmpty)
    }
}
