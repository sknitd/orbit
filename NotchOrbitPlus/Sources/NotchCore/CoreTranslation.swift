import Foundation

public struct OrbitTranslationLanguage: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public static let choices: [Self] = [
        .init(id: "en", title: "English"), .init(id: "es", title: "Spanish"), .init(id: "fr", title: "French"),
        .init(id: "de", title: "German"), .init(id: "it", title: "Italian"), .init(id: "pt", title: "Portuguese"),
        .init(id: "ja", title: "Japanese"), .init(id: "ko", title: "Korean"), .init(id: "zh-Hans", title: "Chinese (Simplified)"),
        .init(id: "ar", title: "Arabic"), .init(id: "hi", title: "Hindi"), .init(id: "ru", title: "Russian")
    ]
}
public struct OrbitTranslationRequest: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let source: String
    public let target: String
    public init(text: String, source: String, target: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 20_000,
              OrbitTranslationLanguage.choices.contains(where: { $0.id == source }),
              OrbitTranslationLanguage.choices.contains(where: { $0.id == target }), source != target else {
            throw AssistantFileFailure.invalid("Enter up to 20 KB of text and choose two different languages.")
        }
        id = UUID(); self.text = trimmed; self.source = source; self.target = target
    }
}
