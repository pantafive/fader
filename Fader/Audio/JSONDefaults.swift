import Foundation
import os

/// The stores persist one JSON blob each in UserDefaults; the codec and its
/// can't-really-fail logging live here once instead of three times.
extension UserDefaults {
    func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func saveJSON(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            // Practically unreachable for the stores' plain Codable shapes;
            // don't fail silently.
            Logger(subsystem: "dev.pantafive.fader", category: "JSONDefaults")
                .error("Failed to encode \(key); not persisted")
            return
        }
        set(data, forKey: key)
    }
}
