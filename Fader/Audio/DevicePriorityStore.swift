import Foundation

/// User-defined output device priority, an ordered list of device UIDs.
/// Position is set by drag-reordering the device list; earlier wins. A drag
/// ranks every visible row (a dropped row must keep its position), so a
/// separate armed set records which devices the user actually moved — only
/// those are auto-switch candidates. Both persist as JSON blobs in
/// UserDefaults.
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

    func loadArmed() -> Set<String> {
        Set(defaults.loadJSON([String].self, forKey: key + "Armed") ?? [])
    }

    func saveArmed(_ armed: Set<String>) {
        defaults.saveJSON(armed.sorted(), forKey: key + "Armed")
    }
}
