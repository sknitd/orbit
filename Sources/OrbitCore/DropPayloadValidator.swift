import Foundation

/// A wheel preview is only a snapshot. The real destination payload must match
/// that snapshot before an action is allowed to consume it.
public enum DropPayloadValidator {
    public static func matchingDroppedURLs(_ dropped: [URL], expected: [URL],
                                           requireExistingFiles: Bool = true) -> [URL]? {
        guard !expected.isEmpty, dropped.count == expected.count,
              dropped.allSatisfy(isLocalFileURL), expected.allSatisfy(isLocalFileURL) else { return nil }
        let actual = dropped.map(canonicalURL)
        let preview = expected.map(canonicalURL)
        guard Set(actual).count == actual.count, Set(actual) == Set(preview) else { return nil }
        if requireExistingFiles && !actual.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return nil }
        // Keep destination URLs, rather than substituting preview URLs. A file
        // provider may attach an access grant to the destination URL.
        return dropped
    }

    private static func isLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let host = url.host, !host.isEmpty else { return true }
        return host.lowercased() == "localhost"
    }

    private static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
    }
}
