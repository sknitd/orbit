import AppKit
import CryptoKit
import Foundation
import Security
import OrbitCore
import NotchCore
import Darwin

enum PlusUpdateInstallError: Error, LocalizedError, Equatable, Sendable {
    case untrustedCurrentApplication, untrustedCandidate, invalidVersion, notNotarized, unsafeArchive, unwritableLocation
    var errorDescription: String? {
        switch self {
        case .untrustedCurrentApplication: "Automatic installation requires a Developer ID signed copy of NotchOrbitPlus. This build can check and download updates for manual installation."
        case .untrustedCandidate: "The update does not have a valid Developer ID signature from this app’s developer."
        case .invalidVersion: "The application inside the download does not match the published update version."
        case .notNotarized: "This update has not passed Apple’s notarized-app assessment. Automatic installation was refused."
        case .unsafeArchive: "The update archive contains unsupported paths or exceeds extraction limits."
        case .unwritableLocation: "This app’s folder is not writable. Download the update and install it manually, or use a writable Applications folder."
        }
    }
}

struct PlusInstalledUpdate: Sendable {
    let applicationURL: URL
    let backupURL: URL
}

/// The trust anchor comes from the running code, never from editable feed metadata.
enum PlusUpdateInstaller {
    private static let developerRequirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"com.sknitd.NotchOrbitPlus\""

    static func currentTrustedTeamIdentifier() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code,
              let requirement = requirement(developerRequirement),
              SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess else {
            throw PlusUpdateInstallError.untrustedCurrentApplication
        }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            throw PlusUpdateInstallError.untrustedCurrentApplication
        }
        return team
    }

    static func validateApplication(at url: URL, expectedVersion: String, requireNotarization: Bool = true) throws {
        let team = try currentTrustedTeamIdentifier()
        var code: SecStaticCode?
        let expression = developerRequirement + " and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code, let requirement = requirement(expression),
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw PlusUpdateInstallError.untrustedCandidate
        }
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.sknitd.NotchOrbitPlus",
              info["CFBundleExecutable"] as? String == "NotchOrbitPlus",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw PlusUpdateInstallError.invalidVersion
        }
        if requireNotarization {
            let assessment = try run(URL(fileURLWithPath: "/usr/sbin/spctl"), ["--assess", "--type", "execute", "--verbose=2", url.path])
            guard assessment.status == 0, assessment.output.contains("Notarized Developer ID") else {
                throw PlusUpdateInstallError.notNotarized
            }
        }
    }

    static func install(archive: URL, feed: CoreUpdateFeed, automatic: Bool) throws -> PlusInstalledUpdate {
        _ = try currentTrustedTeamIdentifier()
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        guard try feed.isNewer(than: currentVersion) else { throw PlusUpdateInstallError.invalidVersion }
        try verifyArchive(archive, feed: feed)
        guard !automatic || feed.signing.notarized else { throw PlusUpdateInstallError.notNotarized }
        let current = Bundle.main.bundleURL.standardizedFileURL
        let parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
            throw PlusUpdateInstallError.unwritableLocation
        }
        let inventory = try ZIPInspector.inspect(archive)
        guard inventory.expandedBytes <= 256 * 1_024 * 1_024 else { throw PlusUpdateInstallError.unsafeArchive }
        let listing = try run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", archive.path])
        guard listing.status == 0, listing.output.split(separator: "\n").allSatisfy({
            $0 == "NotchOrbitPlus.app/" || $0.hasPrefix("NotchOrbitPlus.app/") || $0.hasPrefix("__MACOSX/")
        }) else { throw PlusUpdateInstallError.unsafeArchive }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let unpack = try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, directory.path])
        guard unpack.status == 0 else { throw PlusUpdateInstallError.unsafeArchive }
        let candidate = directory.appendingPathComponent("NotchOrbitPlus.app", isDirectory: true)
        try validateApplication(at: candidate, expectedVersion: feed.version, requireNotarization: automatic)
        let sibling = parent.appendingPathComponent(".NotchOrbitPlus-update-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.copyItem(at: candidate, to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        try validateApplication(at: sibling, expectedVersion: feed.version, requireNotarization: automatic)
        try Task.checkCancellation()
        let backupName = ".NotchOrbitPlus-previous-\(UUID().uuidString).app"
        _ = try FileManager.default.replaceItemAt(current, withItemAt: sibling, backupItemName: backupName, options: [.withoutDeletingBackupItem])
        return PlusInstalledUpdate(applicationURL: current, backupURL: parent.appendingPathComponent(backupName))
    }

    static func rollback(_ update: PlusInstalledUpdate) throws {
        _ = try FileManager.default.replaceItemAt(update.applicationURL, withItemAt: update.backupURL)
    }

    private static func verifyArchive(_ url: URL, feed: CoreUpdateFeed) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == feed.archiveBytes, feed.archiveBytes <= CoreUpdateFeed.maximumArchiveBytes else {
            throw CoreUpdateError.invalidChecksum
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var count = 0
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation(); count += data.count
            guard count <= feed.archiveBytes else { throw CoreUpdateError.invalidChecksum }
            hash.update(data: data)
        }
        try feed.verifySHA256(hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: count)
    }

    private static func requirement(_ expression: String) -> SecRequirement? {
        var value: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(rawValue: 0), &value) == errSecSuccess else { return nil }
        return value
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-assessment-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw PlusUpdateInstallError.unsafeArchive }
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 2 * 1_024 * 1_024 else { throw PlusUpdateInstallError.unsafeArchive }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (process.terminationStatus, String(data: try Data(contentsOf: output), encoding: .utf8) ?? "")
    }
}
