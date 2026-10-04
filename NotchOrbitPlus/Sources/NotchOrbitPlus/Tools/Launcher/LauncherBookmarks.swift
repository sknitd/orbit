import Foundation
import NotchCore

struct PlusLauncherResolution: Sendable {
    let url: URL
    let refreshedBookmark: Data?
}

/// The saved path is a searchable hint. A launch always resolves and checks the
/// bookmark, without displaying permission dialogs or mounting another volume.
enum PlusLauncherBookmarks {
    static func makePin(at source: URL, kind: PlusLauncherKind) throws -> PlusLauncherPin {
        guard kind != .shortcut else { throw failure("Choose a shortcut from the installed Shortcuts list.") }
        guard source.isFileURL, source.host == nil || source.host == "" || source.host == "localhost",
              source.query == nil, source.fragment == nil else { throw failure("Choose a local application or folder.") }
        let url = source.standardizedFileURL.resolvingSymlinksInPath()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try check(url, kind: kind)
        let values = try url.resourceValues(forKeys: [.localizedNameKey])
        let label: String
        if kind == .application {
            let bundle = Bundle(url: url)
            label = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        } else { label = values.localizedName ?? url.lastPathComponent }
        let pin = PlusLauncherPin(label: label, kind: kind, targetIdentifier: url.path,
                                  bookmark: try bookmark(for: url))
        try PlusLauncherPins.validate(pin)
        return pin
    }

    static func resolve(_ pin: PlusLauncherPin) throws -> PlusLauncherResolution {
        try PlusLauncherPins.validate(pin)
        guard pin.kind != .shortcut, let data = pin.bookmark else {
            throw failure("This shortcut has no file target.")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try check(url, kind: pin.kind)
        return PlusLauncherResolution(url: url, refreshedBookmark: stale ? try bookmark(for: url) : nil)
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: [.isApplicationKey, .isDirectoryKey], relativeTo: nil)
    }

    private static func check(_ url: URL, kind: PlusLauncherKind) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw failure("Choose a local application or folder.")
        }
        let values = try url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey])
        switch kind {
        case .application:
            guard values.isApplication == true, Bundle(url: url)?.executableURL != nil else {
                throw failure("The saved target is no longer a valid application. Unpin it and choose the application again.")
            }
        case .folder:
            guard values.isDirectory == true, values.isApplication != true else {
                throw failure("The saved target is no longer a folder. Unpin it and choose the folder again.")
            }
        case .shortcut: throw failure("This shortcut has no file target.")
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NotchOrbitPlus.Launcher", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
