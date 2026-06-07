import Foundation

/// User-defined output device priority, an ordered list of device UIDs.
/// Position is set by drag-reordering the device list; earlier wins. Devices
/// never reordered are unranked and never auto-switched to. Persisted as a
/// single JSON blob in UserDefaults.
struct DevicePriorityStore {
    private let key: String
    private let defaults: UserDefaults

    /// Output and input devices rank independently — pass a distinct key
    /// per direction.
    init(defaults: UserDefaults = .standard, key: String = "devicePriority") {
        self.defaults = defaults
        self.key = key
    }

    /// Folds a reorder of the *visible* rows back into the stored order.
    /// Hidden entries (disconnected Bluetooth, rarely-used devices) keep
    /// their slots — a reorder of unrelated rows must not strip the rank
    /// off headphones that happen to be disconnected right now.
    static func merge(stored: [String], visible: [String]) -> [String] {
        var merged = stored
        for uid in visible where !merged.contains(uid) {
            merged.append(uid)
        }
        let visibleSet = Set(visible)
        let slots = merged.indices.filter { visibleSet.contains(merged[$0]) }
        for (position, slot) in slots.enumerated() {
            merged[slot] = visible[position]
        }
        return merged
    }

    func load() -> [String] {
        defaults.loadJSON([String].self, forKey: key) ?? []
    }

    func save(_ order: [String]) {
        defaults.saveJSON(order, forKey: key)
    }
}
