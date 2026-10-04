import Foundation

public struct GithubRepository: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let fullName: String
    public let htmlURL: URL
    public let isPrivate: Bool
}

public struct GithubWorkflowRun: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let branch: String
    public let status: String
    public let conclusion: String?
    public let updatedAt: Date
    public let htmlURL: URL
    public var resultLabel: String { conclusion ?? status }
}

public struct GithubRunPage: Equatable, Sendable {
    public let totalCount: Int
    public let runs: [GithubWorkflowRun]
}

public enum GithubActionsData {
    public static let pageSize = 50
    public static let maximumRepositoryPages = 5
    public static let maximumRunPages = 3
    public static func repositoryURL(page: Int) throws -> URL {
        try endpoint(path: "/user/repos", page: page, extra: [URLQueryItem(name: "type", value: "owner"), URLQueryItem(name: "sort", value: "updated")], maximum: maximumRepositoryPages)
    }
    public static func runsURL(repository: String, page: Int) throws -> URL {
        guard validRepositoryName(repository) else { throw OnlineDataError.invalid("Choose a valid owner/repository name.") }
        return try endpoint(path: "/repos/\(repository)/actions/runs", page: page, extra: [], maximum: maximumRunPages)
    }
    public static func validRepositoryName(_ value: String) -> Bool {
        value.utf8.count <= 140 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil &&
            ![".", ".."].contains(String(value.split(separator: "/").last ?? ""))
    }
    private static func endpoint(path: String, page: Int, extra: [URLQueryItem], maximum: Int) throws -> URL {
        guard (1...maximum).contains(page) else { throw OnlineDataError.invalid("GitHub pagination limit exceeded.") }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "api.github.com"; parts.path = path
        parts.queryItems = extra + [URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "page", value: String(page))]
        guard let url = parts.url else { throw OnlineDataError.invalid("Invalid GitHub endpoint.") }
        return url
    }
    public static func repositories(_ data: Data) throws -> [GithubRepository] {
        guard data.count <= 4 * 1_024 * 1_024, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= pageSize else { throw OnlineDataError.invalid("GitHub did not return a bounded repository page.") }
        var seen = Set<Int64>()
        return try rows.map { row in
            let id = try integer(row["id"])
            guard seen.insert(id).inserted, let fullName = row["full_name"] as? String, validRepositoryName(fullName),
                  let isPrivate = row["private"] as? Bool else { throw OnlineDataError.invalid("Invalid GitHub repository record.") }
            return GithubRepository(id: id, fullName: fullName, htmlURL: try webURL(row["html_url"]), isPrivate: isPrivate)
        }
    }
    public static func runPage(_ data: Data) throws -> GithubRunPage {
        let root = try OnlineServiceDecoding.object(data)
        let total = try integer(root["total_count"], allowZero: true)
        guard total <= Int64(Int.max), let rows = root["workflow_runs"] as? [[String: Any]], rows.count <= pageSize else {
            throw OnlineDataError.invalid("GitHub did not return a bounded workflow run page.")
        }
        var seen = Set<Int64>()
        let runs = try rows.map { row -> GithubWorkflowRun in
            let id = try integer(row["id"])
            guard seen.insert(id).inserted, let status = row["status"] as? String, !status.isEmpty, status.utf8.count <= 80,
                  let rawBranch = row["head_branch"], rawBranch is String || rawBranch is NSNull else { throw OnlineDataError.invalid("Invalid GitHub workflow run.") }
            let branch = (rawBranch as? String) ?? "No branch"
            guard branch.utf8.count <= 1_024 else { throw OnlineDataError.invalid("Invalid GitHub branch name.") }
            let title = (row["display_title"] as? String) ?? (row["name"] as? String) ?? "Workflow run \(id)"
            guard !title.isEmpty, title.utf8.count <= 4_096 else { throw OnlineDataError.invalid("Invalid workflow title.") }
            let conclusion = row["conclusion"] as? String
            if let raw = row["conclusion"], !(raw is String || raw is NSNull) { throw OnlineDataError.invalid("Invalid workflow conclusion.") }
            guard conclusion == nil || conclusion!.utf8.count <= 80 else { throw OnlineDataError.invalid("Invalid workflow conclusion.") }
            return GithubWorkflowRun(id: id, name: title, branch: branch, status: status, conclusion: conclusion,
                                     updatedAt: try OnlineServiceDecoding.date(row["updated_at"]), htmlURL: try webURL(row["html_url"]))
        }
        return GithubRunPage(totalCount: Int(total), runs: runs)
    }
    private static func integer(_ value: Any?, allowZero: Bool = false) throws -> Int64 {
        let number = try OnlineServiceDecoding.decimal(value)
        let text = NSDecimalNumber(decimal: number).stringValue
        guard let result = Int64(text), result >= (allowZero ? 0 : 1) else { throw OnlineDataError.invalid("Invalid GitHub numeric identifier or count.") }
        return result
    }
    public static func webURL(_ value: Any?) throws -> URL {
        guard let text = value as? String, text.utf8.count <= 4_096, let url = URL(string: text),
              url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw OnlineDataError.invalid("GitHub returned an unsafe browser link.") }
        return url
    }
}
