import Foundation

/// The user's device ranking: the full display order, plus the subset of
/// devices the user has personally dragged. Ranking every visible row is a
/// display necessity (a drop position must persist), so `order` alone cannot
/// mean consent — `armed` does.
struct DeviceRanking {
    var order: [String] = []
    var armed: Set<String> = []
}

/// Pure decisions around the user's device-priority list — display order and
/// auto-switch gating — split from AudioDeviceMonitor so the branchy parts
/// are unit-testable without a HAL. The monitor stays the only HAL toucher.
enum DevicePriorityPolicy {
    /// Position in the priority list; unranked devices sink to `Int.max`.
    static func rank(_ uid: String, priority: [String]) -> Int {
        priority.firstIndex(of: uid) ?? Int.max
    }

    /// Ranked devices in priority order first, unranked after, alphabetical
    /// within equal rank.
    static func ordered(_ list: [AudioDevice], priority: [String]) -> [AudioDevice] {
        list.sorted {
            let lhs = rank($0.uid, priority: priority)
            let rhs = rank($1.uid, priority: priority)
            if lhs != rhs { return lhs < rhs }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// What a device-list refresh means for the default output.
    enum AutoSwitch: Equatable {
        case stay
        /// The previous default disappeared; route to the best-ranked device left.
        case fallback(toUID: String)
        /// Exactly one ranked device appeared and it outranks the default.
        case hotplug(toUID: String)
    }

    /// Gated to explicit events so auto-switch never fights a manual choice:
    /// - the previous default disappeared → override macOS's fallback with
    ///   the best-ranked armed device still present;
    /// - exactly one armed device appeared (hotplug, not a wake storm) and
    ///   it outranks the current default → switch to it.
    ///
    /// Only armed devices (see DeviceRanking) are candidates.
    static func autoSwitch(presentUIDs: [String],
                           previousUIDs: Set<String>,
                           ranking: DeviceRanking,
                           previousDefaultUID: String?,
                           currentDefaultUID: String?) -> AutoSwitch {
        let priority = ranking.order
        func eligible(_ uid: String) -> Bool {
            ranking.armed.contains(uid) && rank(uid, priority: priority) != Int.max
        }

        if let previous = previousDefaultUID, previousUIDs.contains(previous),
           !presentUIDs.contains(previous) {
            if let fallback = presentUIDs
                .filter(eligible)
                .min(by: { rank($0, priority: priority) < rank($1, priority: priority) }),
                fallback != currentDefaultUID {
                return .fallback(toUID: fallback)
            }
            return .stay
        }

        let appeared = presentUIDs.filter { !previousUIDs.contains($0) && eligible($0) }
        guard appeared.count == 1, let candidate = appeared.first, let currentDefaultUID,
              rank(candidate, priority: priority) < rank(currentDefaultUID, priority: priority)
        else { return .stay }
        return .hotplug(toUID: candidate)
    }
}
