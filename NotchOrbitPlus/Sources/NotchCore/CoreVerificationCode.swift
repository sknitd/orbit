import Foundation

public struct CoreVerificationCode: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let code: String
    public let receivedAt: Date
    public let expiresAt: Date
    public init?(id: Int64, text: String, messageDate: Int64, now: Date) {
        let seconds = abs(Double(messageDate)) > 10_000_000_000 ? Double(messageDate) / 1_000_000_000 : Double(messageDate)
        let received = Date(timeIntervalSinceReferenceDate: seconds)
        guard text.utf8.count <= 16_384, received <= now.addingTimeInterval(5),
              received > now.addingTimeInterval(-60), let code = CoreVerificationCodeParser.code(in: text) else { return nil }
        self.id = id; self.code = code; receivedAt = received; expiresAt = min(received.addingTimeInterval(60), now.addingTimeInterval(60))
    }
    public func isVisible(at date: Date) -> Bool { date < expiresAt && date >= receivedAt.addingTimeInterval(-5) }
}

public enum CoreVerificationCodeParser {
    public static func code(in text: String) -> String? {
        guard text.utf8.count <= 16_384 else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"(?i)\b(?:verification|security|login|authentication|confirmation|one[ -]?time|passcode|otp|code)\b|验证码|認証コード|인증"#)
        let digits = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([0-9]{4,8})(?![A-Za-z0-9])"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let keywords = pattern.matches(in: text, range: range)
        guard !keywords.isEmpty else { return nil }
        return digits.matches(in: text, range: range).compactMap { match -> (String, Int)? in
            guard let code = Range(match.range(at: 1), in: text) else { return nil }
            let distance = keywords.map { abs($0.range.location - match.range.location) }.min() ?? Int.max
            guard distance <= 80 else { return nil }
            return (String(text[code]), distance)
        }.min { $0.1 < $1.1 }?.0
    }
}
