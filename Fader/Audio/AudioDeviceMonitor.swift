import CoreAudio
import Observation
import os

/// Watches the devices of one direction and the system default, and switches
/// the default. Usage stamps and drag-priority persist per direction.
@MainActor
@Observable
final class AudioDeviceMonitor {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "AudioDeviceMonitor")

    let direction: AudioDirection

    private(set) var devices: [AudioDevice] = []
    private(set) var defaultDeviceID = AudioDeviceID.unknown

    @ObservationIgnored private var listeners: [HALListener] = []
    // Not observed: stamps change on every refresh, but the view only needs
    // them re-read when defaultDeviceID (observed) moves a device between
    // the main list and the rarely-used group.
    @ObservationIgnored private var lastUsed: [String: Date] = [:]
    @ObservationIgnored private let usageStore: DeviceUsageStore
    // Not observed: every priority change re-sorts `devices`, which is.
    @ObservationIgnored private var priority: [String] = []
    @ObservationIgnored private let priorityStore: DevicePriorityStore
    /// Auto-switch needs a populated baseline — at startup every device
    /// "appears" at once and none of that is a hotplug event.
    @ObservationIgnored private var hasBaseline = false
    @ObservationIgnored private var lastDefaultUID: String?

    init(direction: AudioDirection = .output) {
        self.direction = direction
        let suffix = direction == .input ? "Input" : ""
        usageStore = DeviceUsageStore(key: "deviceLastUsed" + suffix)
        priorityStore = DevicePriorityStore(key: "devicePriority" + suffix)
    }

    func start() {
        lastUsed = usageStore.load()
        priority = priorityStore.load()
        listeners = [
            AudioObjectID.system.listen(kAudioHardwarePropertyDevices) {
                Task { @MainActor [weak self] in self?.refresh() }
            },
            AudioObjectID.system.listen(direction.defaultDeviceSelector) {
                Task { @MainActor [weak self] in self?.refresh() }
            },
        ]
        refresh()
    }

    func setDefault(_ device: AudioDevice) {
        do {
            try AudioObjectID.system.write(direction.defaultDeviceSelector, value: device.id)
            defaultDeviceID = device.id
        } catch {
            Self.logger.error("Failed to set default device to \(device.name): \(error.localizedDescription)")
        }
    }

    /// True when the device hasn't been the default output within the
    /// retention window. The current default is always "in use" regardless of
    /// its stamp — a fresh switch stamps asynchronously, on the next refresh.
    /// Bluetooth is exempt: a connected headset is a deliberate act, and the
    /// disconnected list already lives in its own section.
    func isRarelyUsed(_ device: AudioDevice) -> Bool {
        !device.isBluetooth && device.id != defaultDeviceID && !DeviceUsageStore.isRecent(lastUsed[device.uid])
    }

    /// Persists the new order of the visible rows as the device priority and
    /// re-sorts the list. Hidden devices keep their rank (see merge).
    func applyOrder(_ visibleUIDs: [String]) {
        priority = DevicePriorityStore.merge(stored: priority, visible: visibleUIDs)
        priorityStore.save(priority)
        devices = sorted(devices)
    }

    /// Manual demotion to the rarely-used group: forget the usage stamp.
    /// Using the device again (or auto-switching to it) promotes it back.
    func markRarelyUsed(_ device: AudioDevice) {
        guard device.id != defaultDeviceID, !device.isBluetooth else { return }
        lastUsed[device.uid] = nil
        usageStore.save(lastUsed)
    }

    func refresh() {
        defaultDeviceID = (try? AudioObjectID.readDefaultDevice(direction)) ?? .unknown
        let defaultUID = try? defaultDeviceID.readDeviceUID()
        stampDefaultDevice(uid: defaultUID)

        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        else {
            Self.logger.error("Failed to read device list")
            return
        }

        let previousUIDs = Set(devices.map(\.uid))
        devices = sorted(ids.compactMap { id in
            guard id.channelCount(scope: direction.scope) > 0,
                  let device = AudioDevice(id: id),
                  !device.isFaderPlumbing
            else { return nil }
            return device
        })

        autoSwitch(previousUIDs: previousUIDs, defaultUID: defaultUID)
        lastDefaultUID = defaultUID
        hasBaseline = true
    }

    // MARK: - Priority

    private func sorted(_ list: [AudioDevice]) -> [AudioDevice] {
        DevicePriorityPolicy.ordered(list, priority: priority)
    }

    /// Applies the policy's auto-switch decision (see DevicePriorityPolicy).
    private func autoSwitch(previousUIDs: Set<String>, defaultUID: String?) {
        // While multi-output plays, the default is Fader's own aggregate —
        // priority switching would silently tear the pairing apart.
        guard hasBaseline, defaultUID != MultiOutputController.aggregateUID else { return }

        let decision = DevicePriorityPolicy.autoSwitch(
            presentUIDs: devices.map(\.uid),
            previousUIDs: previousUIDs,
            priority: priority,
            previousDefaultUID: lastDefaultUID,
            currentDefaultUID: defaultUID
        )
        switch decision {
        case .stay:
            return
        case let .fallback(toUID: uid):
            guard let device = devices.first(where: { $0.uid == uid }) else { return }
            Self.logger.info("Default device disappeared; switching to \(device.name)")
            setDefault(device)
        case let .hotplug(toUID: uid):
            guard let device = devices.first(where: { $0.uid == uid }) else { return }
            Self.logger.info("Higher-priority device connected; switching to \(device.name)")
            setDefault(device)
        }
    }

    /// Records that the current default output is in use. Writes are throttled
    /// to one per hour per device — ample granularity for a 30-day window.
    private func stampDefaultDevice(uid: String?, now: Date = Date()) {
        guard let uid, uid != MultiOutputController.aggregateUID else { return }
        if let stamp = lastUsed[uid], now.timeIntervalSince(stamp) < 3600 { return }
        lastUsed[uid] = now
        usageStore.save(lastUsed, now: now)
    }
}

extension AudioObjectID {
    /// Total channels across all streams of the given scope.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let listPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, listPtr) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
