import Foundation

public struct OrbitLRCLine: Sendable, Hashable, Identifiable {
    public let id: Int
    public let time: Double
    public let text: String
}

public enum OrbitLRCParser {
    /// Parses multiple time tags per line; a positive offset delays timestamps.
    public static func parse(_ text: String) -> [OrbitLRCLine] {
        let timing = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"(?im)^\[offset:([+-]?\d+)\]"#)
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var offset = 0.0
        if let match = offsetPattern.firstMatch(in: text, range: full),
           let range = Range(match.range(at: 1), in: text), let milliseconds = Double(text[range]) {
            offset = milliseconds / 1_000
        }
        var values: [(Double, String, Int)] = []
        for line in text.components(separatedBy: .newlines) {
            let matches = timing.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            guard let last = matches.last, let end = Range(last.range, in: line)?.upperBound else { continue }
            let words = String(line[end...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minuteRange]), let seconds = Double(line[secondRange]), seconds < 60 else { continue }
                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = line[fractionRange]
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                values.append((max(0, minutes * 60 + seconds + fraction + offset), words, values.count))
            }
        }
        return values.sorted { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
            .enumerated().map { OrbitLRCLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    public static func activeIndex(in lines: [OrbitLRCLine], at seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        return lines.lastIndex { $0.time <= seconds }
    }
}

public struct OrbitShortcutChoice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
}

public enum OrbitShortcutListing {
    /// `shortcuts list --show-identifiers` supplies a stable UUID per shortcut.
    public static func parse(_ output: String) throws -> [OrbitShortcutChoice] {
        let pattern = try NSRegularExpression(pattern: #"^(.*)\s+\(([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)$"#)
        var results: [OrbitShortcutChoice] = []
        var seen = Set<String>()
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  let nameRange = Range(match.range(at: 1), in: line), let idRange = Range(match.range(at: 2), in: line) else {
                throw NSError(domain: "NotchOrbitPlus.Shortcuts", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Shortcuts listing format could not be read. Open Shortcuts and refresh the list."])
            }
            let identifier = String(line[idRange]).uppercased()
            guard seen.insert(identifier).inserted else { continue }
            results.append(OrbitShortcutChoice(id: identifier, name: String(line[nameRange])))
        }
        return results
    }
}
