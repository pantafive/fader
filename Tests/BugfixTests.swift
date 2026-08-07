import Foundation
import Testing

// BUG: auto-switch targeted Bluetooth devices the user never chose.
//
// Reported: owner, 2026-07-10 — earbuds taken off the charger grabbed the
//   Mac's output and mic; calls dropped to HFP (robotic voice).
// Date: 2026-07-10
//
// What happened:
//   One drag in the device list ranked EVERY visible device (a drop position
//   only persists if all rows are ranked), so the earbuds entered the
//   priority list unchosen at rank 1 for both directions. Their every
//   reconnect then satisfied the hotplug rule and yanked the default output
//   and input onto them mid-call.
//
// Root cause:
//   Rank doubled as auto-switch consent; ranking is a display necessity.
//
// Fix:
//   DevicePriorityPolicy.autoSwitch gained an `armed` set — UIDs the user
//   personally dragged (AudioDeviceMonitor.applyOrder records the moved row
//   only). Unarmed devices are never switched to; existing installs start
//   with an empty set, disarming auto-switch until a deliberate drag.
@Suite("bugfixes: auto-switch arming")
struct BugAutoSwitchArmingTests {
    @Test("bug: ranked but never-dragged device must not capture the default")
    func bugUnarmedHotplugStays() {
        // The earbuds sit at rank 1 because a drag of another row ranked the
        // whole visible list — but the user never moved them.
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "earbuds"],
            previousUIDs: ["speakers"],
            ranking: DeviceRanking(order: ["earbuds", "speakers"], armed: ["speakers"]),
            previousDefaultUID: "speakers",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .stay)
    }

    @Test("bug: fallback must skip ranked but never-dragged devices")
    func bugUnarmedFallbackStays() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["earbuds", "speakers"],
            previousUIDs: ["mic", "earbuds", "speakers"],
            ranking: DeviceRanking(order: ["earbuds", "mic", "speakers"], armed: []),
            previousDefaultUID: "mic",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .stay)
    }

    @Test("armed and ranked device still hotplugs — the feature survives")
    func armedHotplugSwitches() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "earbuds"],
            previousUIDs: ["speakers"],
            ranking: DeviceRanking(order: ["earbuds", "speakers"], armed: ["earbuds"]),
            previousDefaultUID: "speakers",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .hotplug(toUID: "earbuds"))
    }

    @Test("armed set round-trips and starts empty for existing installs")
    func armedRoundTrip() throws {
        let suite = "BugAutoSwitchArmingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = DevicePriorityStore(defaults: defaults)

        #expect(store.loadArmed().isEmpty)
        store.saveArmed(["earbuds"])
        #expect(store.loadArmed() == ["earbuds"])
    }
}
