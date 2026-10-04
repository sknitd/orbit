import Foundation
import Darwin

@main
enum PluginSandboxProbe {
    static func main() async {
        let report = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var results: [[String: String]] = []
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitPluginProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            let plugin = fixture.appendingPathComponent("plugin", isDirectory: true)
            try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = plugin.appendingPathComponent("fixture.sh")
            let command = CorePluginCommand(id: "fixture", script: "fixture.sh")
            let profile = try PlusPluginSandbox.profile(folder: plugin, writable: false, readFolders: [])
            try profile.write(to: report.appendingPathComponent("production.sb"), atomically: true, encoding: .utf8)
            func run(_ source: String, readFolders: [URL] = []) async throws -> Data {
                try Data(source.utf8).write(to: script)
                return try await PlusPluginProcess().run(folder: plugin, command: command,
                    grants: readFolders.isEmpty ? [] : [.selectedFolderRead], readFolders: readFolders, clipboard: nil)
            }
            let output = try await run("printf '%s' '{\"items\":[{\"kind\":\"text\",\"text\":\"Actual sandbox fixture\"}]}'")
            let json = try JSONSerialization.jsonObject(with: output) as? [String: Any]
            guard json?["items"] != nil else { throw CorePluginError.invalid("Production runner did not emit the expected JSON.") }
            results.append(["test": "builtin-json", "outcome": "passed", "output": String(decoding: output, as: UTF8.self)])
            let outside = fixture.appendingPathComponent("outside.txt"), original = Data("preserve exact original\n".utf8)
            try original.write(to: outside)
            let escaped = outside.path.replacingOccurrences(of: "'", with: "'\\''")
            let denied = try await run("if printf changed > '\(escaped)'; then printf ALLOWED; else printf BLOCKED; fi")
            guard String(decoding: denied, as: UTF8.self).contains("BLOCKED"), try Data(contentsOf: outside) == original else {
                throw CorePluginError.invalid("Sandbox outside-write assertion failed.")
            }
            results.append(["test": "outside-write", "outcome": "passed"])
            let readScript = "if IFS= read -r value < '\(escaped)'; then printf 'ALLOWED:%s' \"$value\"; else printf BLOCKED; fi"
            let deniedRead = try await run(readScript)
            guard String(decoding: deniedRead, as: UTF8.self).contains("BLOCKED") else { throw CorePluginError.invalid("Sandbox outside-read assertion failed.") }
            results.append(["test": "outside-read", "outcome": "passed"])
            let grantedRead = try await run(readScript, readFolders: [fixture])
            guard String(decoding: grantedRead, as: UTF8.self) == "ALLOWED:preserve exact original", try Data(contentsOf: outside) == original else {
                throw CorePluginError.invalid("Sandbox explicit read-folder grant assertion failed.")
            }
            results.append(["test": "explicit-folder-read", "outcome": "passed"])
            try JSONSerialization.data(withJSONObject: ["outcome": "passed", "checks": results], options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("status.json"))
        } catch {
            let failure: [String: Any] = ["outcome": "failed", "checks": results, "diagnostic": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: report.appendingPathComponent("status.json"))
            }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
