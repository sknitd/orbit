import Foundation
import CryptoKit
import OrbitCore

struct FileEngine: ActionEngine {
    func perform(_ action: ActionID, items: [FileItem], context: ActionContext) async throws -> ActionResult {
        let worker = Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            do {
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    let stem = item.url.deletingPathExtension().lastPathComponent
                    let output: URL
                    switch action {
                    case .duplicate:
                        output = try OutputTransaction.write(source: item.url, outputDirectory: context.outputDirectory,
                            stem: stem + " copy", extension: item.url.pathExtension,
                            writer: { try FileManager.default.copyItem(at: item.url, to: $0) },
                            validate: { url in
                                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                guard Int64(size) == item.byteCount else { throw OrbitError.failed("Copy size did not match the original.") }
                            })
                    case .checksum:
                        let handle = try FileHandle(forReadingFrom: item.url)
                        defer { try? handle.close() }
                        var hash = SHA256()
                        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                            try Task.checkCancellation()
                            hash.update(data: block)
                        }
                        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                        let name = item.url.lastPathComponent
                        guard !name.contains("\n"), !name.contains("\r"), !name.contains("\\") else {
                            throw OrbitError.invalidInput("Rename this file before writing a portable checksum manifest.")
                        }
                        let data = Data((digest + "  " + name + "\n").utf8)
                        output = try OutputTransaction.write(source: item.url, outputDirectory: context.outputDirectory,
                            stem: item.url.lastPathComponent, extension: "sha256",
                            writer: { try data.write(to: $0) }, validate: { _ in })
                    case .formatJSON, .minifyJSON:
                        guard item.byteCount <= 50_000_000 else { throw OrbitError.invalidInput("JSON formatting is limited to 50 MB.") }
                        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: item.url), options: [.fragmentsAllowed])
                        let options: JSONSerialization.WritingOptions = action == .formatJSON ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.fragmentsAllowed, .sortedKeys]
                        let data = try JSONSerialization.data(withJSONObject: object, options: options)
                        output = try OutputTransaction.write(source: item.url, outputDirectory: context.outputDirectory,
                            stem: stem + (action == .formatJSON ? " formatted" : " minified"), extension: "json",
                            writer: { try data.write(to: $0) },
                            validate: { _ = try JSONSerialization.jsonObject(with: Data(contentsOf: $0), options: [.fragmentsAllowed]) })
                    default: throw OrbitError.unsupported("This file operation is unavailable.")
                    }
                    outputs.append(output)
                    context.progress(Double(index + 1) / Double(items.count), "\(index + 1) / \(items.count)")
                }
                return ActionResult(outputs: outputs, inputBytes: items.reduce(0) { $0 + $1.byteCount },
                    outputBytes: try outputs.reduce(0) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) })
            } catch {
                for output in outputs { try? FileManager.default.removeItem(at: output) }
                throw error
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
