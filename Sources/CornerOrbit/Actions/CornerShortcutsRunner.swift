import Foundation
import CornerCore

protocol CornerShortcutsExecuting: Sendable {
    func run(name: String) async throws
}

struct CornerShortcutsRunner: CornerShortcutsExecuting {
    let timeout: TimeInterval
    let outputLimit: Int
    init(timeout: TimeInterval = 30, outputLimit: Int = 32_768) {
        self.timeout = min(60, max(0.05, timeout.isFinite ? timeout : 30))
        self.outputLimit = min(65_536, max(1_024, outputLimit))
    }
    func run(name: String) async throws {
        let arguments = try Self.arguments(for: name)
        try Task.checkCancellation()
        _ = try await CornerCommandProcess(timeout: timeout, outputLimit: outputLimit).run(
            executable: URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: arguments)
        try Task.checkCancellation()
    }
    static func arguments(for name: String) throws -> [String] {
        ["run", try CornerActionArgumentValidation.shortcutName(name)]
    }
    /// The settings UI calls this only after an explicit Refresh; initialization never executes it.
    func list() async throws -> [String] {
        let data = try await CornerCommandProcess(timeout: timeout, outputLimit: outputLimit).run(
            executable: URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["list"])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CornerActionError.invalid("Shortcuts returned a list that is not valid UTF-8.")
        }
        return try text.split(whereSeparator: \.isNewline).prefix(256).map {
            try CornerActionArgumentValidation.shortcutName(String($0))
        }
    }
}
