import CoreAudio
import Foundation
import Testing

private func device(_ uid: String, name: String? = nil, bluetooth: Bool = false) -> AudioDevice {
    AudioDevice(id: AudioDeviceID(0), uid: uid, name: name ?? uid,
                transport: bluetooth ? kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeBuiltIn,
                outputDataSource: 0, inputDataSource: 0)
}

@Suite("DevicePriorityPolicy.ordered")
struct DevicePriorityOrderTests {
    @Test("ranked devices come first, in priority order")
    func rankedFirst() {
        let list = [device("c"), device("a"), device("b")]

        let ordered = DevicePriorityPolicy.ordered(list, priority: ["b", "c"])

        #expect(ordered.map(\.uid) == ["b", "c", "a"])
    }

    @Test("unranked devices sort alphabetically, case-insensitive")
    func unrankedAlphabetical() {
        let list = [device("u1", name: "zoom"), device("u2", name: "Anker"), device("u3", name: "mic")]

        let ordered = DevicePriorityPolicy.ordered(list, priority: [])

        #expect(ordered.map(\.name) == ["Anker", "mic", "zoom"])
    }
}

@Suite("DevicePriorityPolicy.autoSwitch")
struct AutoSwitchPolicyTests {
    @Test("switches to a lone appeared device that outranks the default")
    func hotplugOutranking() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "headphones"],
            previousUIDs: ["speakers"],
            priority: ["headphones", "speakers"],
            previousDefaultUID: "speakers",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .hotplug(toUID: "headphones"))
    }

    @Test("stays when the appeared device ranks below the default")
    func hotplugLowerRank() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "headphones"],
            previousUIDs: ["speakers"],
            priority: ["speakers", "headphones"],
            previousDefaultUID: "speakers",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .stay)
    }

    @Test("stays when two ranked devices appear at once (wake storm)")
    func simultaneousAppearance() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "headphones", "dock"],
            previousUIDs: ["speakers"],
            priority: ["headphones", "dock", "speakers"],
            previousDefaultUID: "speakers",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .stay)
    }

    @Test("stays when the appeared device was never ranked")
    func unrankedAppearance() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "stranger"],
            previousUIDs: ["speakers"],
            priority: ["speakers"],
            previousDefaultUID: "speakers",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .stay)
    }

    @Test("stays when there is no current default to compare against")
    func noCurrentDefault() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["speakers", "headphones"],
            previousUIDs: ["speakers"],
            priority: ["headphones"],
            previousDefaultUID: nil,
            currentDefaultUID: nil
        )

        #expect(decision == .stay)
    }

    @Test("falls back to the best-ranked survivor when the default disappears")
    func defaultDisappeared() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["dock", "speakers"],
            previousUIDs: ["headphones", "dock", "speakers"],
            priority: ["headphones", "dock", "speakers"],
            previousDefaultUID: "headphones",
            currentDefaultUID: "speakers"
        )

        #expect(decision == .fallback(toUID: "dock"))
    }

    @Test("stays when macOS already fell back to the best-ranked device")
    func fallbackAlreadyDefault() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["dock", "speakers"],
            previousUIDs: ["headphones", "dock", "speakers"],
            priority: ["headphones", "dock", "speakers"],
            previousDefaultUID: "headphones",
            currentDefaultUID: "dock"
        )

        #expect(decision == .stay)
    }

    @Test("stays when the default disappears and nothing ranked remains")
    func noRankedSurvivor() {
        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: ["stranger"],
            previousUIDs: ["headphones", "stranger"],
            priority: ["headphones"],
            previousDefaultUID: "headphones",
            currentDefaultUID: "stranger"
        )

        #expect(decision == .stay)
    }
}
