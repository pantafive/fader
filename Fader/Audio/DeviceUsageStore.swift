import Foundation
import os

/// Last time each output device was the system default, keyed by device UID.
/// Persisted as a single JSON blob in UserDefaults; entries past the retention
/// window are pruned on save, so absence means "not used lately".
struct DeviceUsageStore {
    /// Devices unused for this long collapse into the "Rarely used" group.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let key: String
    private let defaults: UserDefaults

    /// Output and input devices keep separate histories — pass a distinct key
    /// per direction.
    init(defaults: UserDefaults = .standard, key: String = "deviceLastUsed") {
        self.defaults = defaults
        self.key = key
    }

    static func isRecent(_ lastUsed: Date?, now: Date = Date()) -> Bool {
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) < retention
    }

    func load() -> [String: Date] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ usage: [String: Date], now: Date = Date()) {
        let live = usage.filter { Self.isRecent($0.value, now: now) }
        guard let data = try? JSONEncoder().encode(live) else {
            // Practically unreachable for [String: Date]; don't fail silently.
            Logger(subsystem: "dev.pantafive.fader", category: "DeviceUsageStore")
                .error("Failed to encode device usage; not persisted")
            return
        }
        defaults.set(data, forKey: key)
    }
}
