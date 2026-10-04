import AppKit
import SwiftUI

enum LocalToolStorage {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("NotchOrbitPlus/LocalTools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }
    static func load<Value: Decodable>(_ type: Value.Type, file: String, fallback: Value) throws -> Value {
        let url = try directory().appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 40 * 1_024 * 1_024 {
            throw CocoaError(.fileReadTooLarge)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func save<Value: Codable>(_ value: Value, file: String) throws {
        let url = try directory().appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let valid = size <= 40 * 1_024 * 1_024 &&
                (try? JSONDecoder().decode(Value.self, from: Data(contentsOf: url))) != nil
            if !valid {
                // A user action may create fresh state after a load error, but
                // it must not destroy the unreadable original in the process.
                let backup = url.deletingLastPathComponent().appendingPathComponent("\(file).\(UUID().uuidString).backup")
                try FileManager.default.copyItem(at: url, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct LocalToolError: View {
    let message: String?
    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
