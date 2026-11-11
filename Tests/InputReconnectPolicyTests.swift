import Foundation
import Testing

@Suite("Input reconnect")
struct InputReconnectPolicyTests {
    private let start = Date(timeIntervalSince1970: 1000)

    /// A brief USB loss left the microphone on the fallback after reconnecting.
    @Test("bug: returns to the microphone within one second", arguments: [0.5, 1.0])
    func bugBriefDisconnect(elapsed: TimeInterval) {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: "built-in", now: start)

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                                      now: start.addingTimeInterval(elapsed))

        #expect(restored == "usb")
    }

    @Test("does not restore a microphone that was inactive before disconnecting")
    func inactiveReconnect() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in", now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: "built-in", now: start)

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                                      now: start.addingTimeInterval(1))

        #expect(restored == nil)
    }

    @Test("leaves the fallback after the reconnect window expires")
    func expiredReconnect() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: "built-in", now: start)

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                                      now: start.addingTimeInterval(1.001))

        #expect(restored == nil)
    }

    @Test("honors a manual selection in Fader, including the fallback", arguments: ["built-in", "other"])
    func manualSelection(uid: String) {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in", "other"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in", "other"], defaultUID: "built-in", now: start)
        policy.cancel()
        policy.didSwitch(to: uid)

        let restored = policy.refresh(devices: ["usb", "built-in", "other"], defaultUID: uid,
                                      now: start.addingTimeInterval(1))

        #expect(restored == nil)
    }

    @Test("honors a default change outside Fader while waiting")
    func externalSelection() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in", "other"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in", "other"], defaultUID: "built-in", now: start)

        let restored = policy.refresh(devices: ["usb", "built-in", "other"], defaultUID: "other",
                                      now: start.addingTimeInterval(1))

        #expect(restored == nil)
    }

    @Test("does not override an ordinary default change while the microphone remains connected")
    func connectedSelection() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb", now: start)

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                                      now: start.addingTimeInterval(1))

        #expect(restored == nil)
    }

    @Test("does not switch to microphones present at startup")
    func startup() {
        var policy = InputReconnectPolicy()

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in", now: start)

        #expect(restored == nil)
    }

    @Test("retains the original microphone when priority switching chooses a fallback")
    func priorityFallback() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in", "other"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in", "other"], defaultUID: "built-in", now: start)
        policy.didSwitch(to: "other")

        let restored = policy.refresh(devices: ["usb", "built-in", "other"], defaultUID: "other",
                                      now: start.addingTimeInterval(1))

        #expect(restored == "usb")
    }

    @Test("waits through a temporary absence of a default input")
    func missingDefault() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: nil, now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: "built-in", now: start.addingTimeInterval(0.25))

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                                      now: start.addingTimeInterval(0.5))

        #expect(restored == "usb")
    }

    @Test("keeps the return pending until a switch succeeds")
    func failedSwitch() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: "built-in", now: start)
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                           now: start.addingTimeInterval(0.25))

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                                      now: start.addingTimeInterval(0.5))

        #expect(restored == "usb")
    }

    @Test("finishes recovery after a successful return")
    func successfulSwitch() {
        var policy = InputReconnectPolicy()
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb", now: start)
        _ = policy.refresh(devices: ["built-in"], defaultUID: "built-in", now: start)
        _ = policy.refresh(devices: ["usb", "built-in"], defaultUID: "built-in",
                           now: start.addingTimeInterval(1))
        policy.didSwitch(to: "usb")

        let restored = policy.refresh(devices: ["usb", "built-in"], defaultUID: "usb",
                                      now: start.addingTimeInterval(2))

        #expect(restored == nil)
    }
}
