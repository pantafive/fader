import CoreAudio
import Testing

private func device(_ uid: String, bluetooth: Bool = false) -> AudioDevice {
    AudioDevice(id: AudioDeviceID(0), uid: uid, name: uid,
                transport: bluetooth ? kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeBuiltIn,
                outputDataSource: 0, inputDataSource: 0)
}

@Suite("MultiOutputPolicy.clock")
struct MultiOutputClockTests {
    @Test("prefers the first wired member over an earlier Bluetooth one")
    func wiredOverBluetooth() {
        let members = [device("buds", bluetooth: true), device("speakers"), device("dock")]

        #expect(MultiOutputPolicy.clock(among: members)?.uid == "speakers")
    }

    @Test("falls back to the first member when all are Bluetooth")
    func allBluetooth() {
        let members = [device("buds", bluetooth: true), device("box", bluetooth: true)]

        #expect(MultiOutputPolicy.clock(among: members)?.uid == "buds")
    }

    @Test("no members, no clock")
    func empty() {
        #expect(MultiOutputPolicy.clock(among: []) == nil)
    }
}

@Suite("MultiOutputPolicy.resolution")
struct MultiOutputResolutionTests {
    @Test("two survivors keep multi-output alive")
    func twoSurvivors() {
        let survivors = [device("a"), device("b")]

        #expect(MultiOutputPolicy.resolution(survivors: survivors) == .reapply(survivors))
    }

    @Test("a single survivor dissolves to that device")
    func singleSurvivor() {
        let survivor = device("a")

        #expect(MultiOutputPolicy.resolution(survivors: [survivor]) == .dissolve(to: survivor))
    }

    @Test("no survivors dissolves to nothing")
    func noSurvivors() {
        #expect(MultiOutputPolicy.resolution(survivors: []) == .dissolve(to: nil))
    }
}
