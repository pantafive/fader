import Foundation

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
        defaults.loadJSON([String: Date].self, forKey: key) ?? [:]
    }

    func save(_ usage: [String: Date], now: Date = Date()) {
        defaults.saveJSON(usage.filter { Self.isRecent($0.value, now: now) }, forKey: key)
    }
}
