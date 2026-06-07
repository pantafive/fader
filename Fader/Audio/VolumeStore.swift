import Foundation

/// Per-app volume settings persisted across launches, keyed by bundle identifier.
struct AppVolume: Codable, Equatable {
    var volume: Float = 1.0
    var isMuted: Bool = false

    /// Unity gain and unmuted — the app's audio path does not need a tap.
    var isNeutral: Bool { volume == 1.0 && !isMuted }
}

/// Persists app volumes as a single JSON blob in UserDefaults.
struct VolumeStore {
    private static let key = "appVolumes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: AppVolume] {
        defaults.loadJSON([String: AppVolume].self, forKey: Self.key) ?? [:]
    }

    func save(_ volumes: [String: AppVolume]) {
        // Neutral entries carry no information — drop them to keep the blob minimal.
        defaults.saveJSON(volumes.filter { !$0.value.isNeutral }, forKey: Self.key)
    }
}
