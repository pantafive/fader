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

// BUG: apps jumped to full volume when their tap was rebuilt.
//
// Reported: GitHub issue, 2026-10-13 — painful volume spikes on Bluetooth
//   headphones that ignore the macOS volume, so Fader was the only attenuation.
// Date: 2026-10-14
//
// What happened:
//   Every rebuild (new helper process, output change, dead aggregate) destroyed
//   the old tap before building the new one, handing the app its native output
//   at full volume in between. A failed rebuild was never retried while the
//   app kept playing steadily, and a parked tap that failed to restart
//   destroyed itself without a replacement — the app stayed at full volume.
//
// Root cause:
//   Teardown came first and nothing scheduled another attempt.
//
// Fix:
//   MixerEngine builds the replacement before retiring the old tap, retries
//   failures on TapRebuildPolicy's backoff, and holds a broken tap silent
//   meanwhile. Building real taps needs a live HAL, so the hold and retry
//   timing is what is pinned here.
@Suite("bugfixes: tap rebuild volume spikes")
struct BugTapRebuildSpikeTests {
    @Test("bug: a just-failed rebuild holds the app silent instead of releasing it")
    func bugFreshFailureHolds() {
        let failed = ContinuousClock.Instant.now

        let decision = TapRebuildPolicy.brokenTap(failingSince: failed, now: failed + .seconds(2))

        #expect(decision == .hold)
    }

    @Test("a rebuild failing past the hold limit releases the app")
    func longFailureReleases() {
        let failed = ContinuousClock.Instant.now

        let decision = TapRebuildPolicy.brokenTap(failingSince: failed,
                                                  now: failed + TapRebuildPolicy.holdLimit)

        #expect(decision == .release)
    }

    @Test("bug: retries start fast and back off to the cap", arguments: [
        (1, Duration.milliseconds(250)),
        (2, .milliseconds(500)),
        (4, .seconds(2)),
        (5, .seconds(4)),
        (40, .seconds(4)),
    ])
    func bugRetryBackoff(failures: Int, expected: Duration) {
        #expect(TapRebuildPolicy.retryDelay(afterFailures: failures) == expected)
    }
}
