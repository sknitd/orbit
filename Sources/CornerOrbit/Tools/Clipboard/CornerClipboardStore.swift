import AppKit
import Combine
import CornerCore

@MainActor final class CornerClipboardStore: ObservableObject {
    static let shared = CornerClipboardStore()
    @Published var input = "" { didSet { output = "" } }
    @Published private(set) var output = ""
    @Published var mode: CornerClipboardMode = .plainText { didSet { output = "" } }
    @Published private(set) var snapshotString: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var status = "Read explicitly; clipboard contents stay in memory only."
    @Published private(set) var canUndo = false
    private let pasteboard: NSPasteboard
    private let isPreview: Bool
    private var readChangeCount: Int?
    private var ownChangeCount: Int?
    private var undoItems: [[(NSPasteboard.PasteboardType, Data)]]?
    private var publishedItems: [[(NSPasteboard.PasteboardType, Data)]]?
    private static let maximumBackupBytes = 2_097_152

    init(preview: Bool = false, pasteboard: NSPasteboard? = nil, previewText: String = "") {
        isPreview = preview
        self.pasteboard = pasteboard ?? (preview ? NSPasteboard(name: .init("CornerOrbit.Preview.\(UUID().uuidString)")) : .general)
        if preview { input = String(previewText.prefix(CornerClipboardTransform.maximumInputBytes)); snapshotString = input }
        // Constructor never queries any pasteboard data or type.
    }
    func read() throws {
        try reportErrors {
            if isPreview { snapshotString = input; status = "Preview text loaded; the real clipboard was not read."; return }
            let count = pasteboard.changeCount
            guard let value = pasteboard.string(forType: .string) else { throw CornerClipboardError.noText }
            guard value.utf8.count <= CornerClipboardTransform.maximumInputBytes else { throw CornerClipboardError.inputTooLarge }
            guard pasteboard.changeCount == count else { throw CornerClipboardError.clipboardChanged }
            input = value; snapshotString = value; readChangeCount = count; status = "Loaded text from the clipboard. Preview before Apply."
        }
    }
    @discardableResult func preview(kind: CornerActionKind) throws -> String {
        guard let selected = Self.mode(for: kind) else { throw CornerClipboardError.unknownAction }
        mode = selected; return try preview()
    }
    @discardableResult func preview() throws -> String {
        try reportErrors {
            guard snapshotString != nil else { throw CornerClipboardError.readFirst }
            let transformed = try CornerClipboardTransform.apply(input, mode: mode)
            output = transformed; status = "Preview ready. The clipboard is unchanged."; return transformed
        }
    }
    @discardableResult func apply() throws -> String {
        try reportErrors {
            let replacement = try preview()
            if isPreview { input = replacement; output = replacement; snapshotString = replacement; status = "Preview only — no clipboard write."; return status }
            guard let readChangeCount, pasteboard.changeCount == readChangeCount,
                  pasteboard.string(forType: .string) == snapshotString else { throw CornerClipboardError.clipboardChanged }
            let original = try captureOriginal(expectedCount: readChangeCount)
            let item = NSPasteboardItem()
            guard item.setString(replacement, forType: .string), let publishedText = item.data(forType: .string),
                  pasteboard.changeCount == readChangeCount, pasteboard.string(forType: .string) == snapshotString else { throw CornerClipboardError.clipboardChanged }
            let clearedCount = pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                undoItems = original; ownChangeCount = pasteboard.changeCount; publishedItems = nil; canUndo = false
                if pasteboard.changeCount == clearedCount, let restored = try? restoredItems(original), (restored.isEmpty || pasteboard.writeObjects(restored)) { undoItems = nil; ownChangeCount = nil; self.readChangeCount = pasteboard.changeCount }
                throw CornerClipboardError.writeFailed
            }
            undoItems = original; ownChangeCount = pasteboard.changeCount; canUndo = true
            publishedItems = [[(.string, publishedText)]]
            self.readChangeCount = pasteboard.changeCount; input = replacement; output = replacement; snapshotString = replacement
            status = "Applied \(mode.title). One-step Undo is available while the clipboard still contains this write."; return status
        }
    }
    @discardableResult func undo() throws -> String {
        try reportErrors {
            guard let original = undoItems, let ownChangeCount, let publishedItems else { throw CornerClipboardError.noUndo }
            guard pasteboard.changeCount == ownChangeCount else { canUndo = false; throw CornerClipboardError.clipboardChanged }
            let current = try captureOriginal(expectedCount: ownChangeCount, maximumBytes: CornerClipboardTransform.maximumOutputBytes + 256)
            guard sameItems(current, publishedItems) else { canUndo = false; throw CornerClipboardError.clipboardChanged }
            let restored = try restoredItems(original)
            guard pasteboard.changeCount == ownChangeCount else { canUndo = false; throw CornerClipboardError.clipboardChanged }
            pasteboard.clearContents()
            guard restored.isEmpty || pasteboard.writeObjects(restored) else { self.ownChangeCount = pasteboard.changeCount; throw CornerClipboardError.writeFailed }
            undoItems = nil; self.publishedItems = nil; self.ownChangeCount = nil; canUndo = false; readChangeCount = nil; snapshotString = nil; input = ""; output = ""
            status = "Restored the original clipboard item types and bytes. Choose Read before another transform."; return status
        }
    }
    @discardableResult func perform(kind: CornerActionKind) throws -> String {
        if kind == .clipboardUndo { return try undo() }
        guard let selected = Self.mode(for: kind) else { throw CornerClipboardError.unknownAction }
        try read(); mode = selected; return try apply()
    }
    private func captureOriginal(expectedCount: Int, maximumBytes: Int = 2_097_152) throws -> [[(NSPasteboard.PasteboardType, Data)]] {
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 16 else { throw CornerClipboardError.backupTooLarge }
        var total = 0, captured: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            guard item.types.count <= 32 else { throw CornerClipboardError.backupTooLarge }
            var types: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let bytes = item.data(forType: type) else { throw CornerClipboardError.cannotBackup }
                total += bytes.count + type.rawValue.utf8.count
                guard total <= maximumBytes else { throw CornerClipboardError.backupTooLarge }
                types.append((type, bytes))
            }
            captured.append(types)
        }
        guard pasteboard.changeCount == expectedCount else { throw CornerClipboardError.clipboardChanged }
        return captured
    }
    private func sameItems(_ lhs: [[(NSPasteboard.PasteboardType, Data)]], _ rhs: [[(NSPasteboard.PasteboardType, Data)]]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard left.count == right.count else { return false }
            return left.allSatisfy { type, bytes in right.contains { $0.0 == type && $0.1 == bytes } }
        }
    }
    private func restoredItems(_ originals: [[(NSPasteboard.PasteboardType, Data)]]) throws -> [NSPasteboardItem] {
        try originals.map { types in
            let item = NSPasteboardItem()
            for (type, bytes) in types { guard item.setData(bytes, forType: type) else { throw CornerClipboardError.cannotBackup } }
            return item
        }
    }
    private func reportErrors<T>(_ operation: () throws -> T) throws -> T {
        do { let result = try operation(); errorMessage = nil; return result }
        catch { errorMessage = error.localizedDescription; throw error }
    }
    static func mode(for kind: CornerActionKind) -> CornerClipboardMode? {
        switch kind {
        case .clipboardPlainText: .plainText
        case .clipboardJSONPretty: .jsonPretty
        case .clipboardJSONMinify: .jsonMinify
        case .clipboardURLEncode: .urlEncode
        case .clipboardURLDecode: .urlDecode
        case .clipboardBase64Encode: .base64Encode
        case .clipboardBase64Decode: .base64Decode
        case .clipboardUppercase: .uppercase
        case .clipboardLowercase: .lowercase
        case .clipboardTitleCase: .titleCase
        case .clipboardSnakeCase: .snakeCase
        case .clipboardKebabCase: .kebabCase
        case .clipboardStripTracking: .stripTracking
        case .clipboardTrimLines: .trimLines
        case .clipboardDedupeLines: .dedupeLines
        default: nil
        }
    }
}
