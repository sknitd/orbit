import Foundation
import NotchCore

enum PlusPortableDefaults {
    /// A malformed property-list value is an unreadable original, not an absent setting.
    static func data(_ key: String, in defaults: UserDefaults) throws -> Data? {
        guard let original = defaults.object(forKey: key) else { return nil }
        guard let data = original as? Data else { throw SyncFailure.invalid("Saved portable configuration has an unexpected property type. Its original is retained.") }
        return data
    }
}
