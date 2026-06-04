import CoreAudio
import Observation
import os

/// An audio device with channels in the monitored direction.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// CoreAudio UIDs for Bluetooth devices start with the MAC address,
    /// e.g. "50-C0-F0-00-1C-78:output" — IOBluetooth uses the same dashed form.
    func matches(bluetoothID: String) -> Bool {
        uid.lowercased().hasPrefix(bluetoothID.lowercased())
    }

    /// SF Symbol matching the device's transport type.
    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            "airpods.gen3"
        case kAudioDeviceTransportTypeBuiltIn:
            "laptopcomputer"
        case kAudioDeviceTransportTypeUSB:
            "cable.connector"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            "display"
        case kAudioDeviceTransportTypeAirPlay:
            "airplay.audio"
        default:
            "hifispeaker"
        }
    }
}

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
                  let uid = try? id.readDeviceUID(),
                  let name = try? id.readString(kAudioObjectPropertyName)
            else { return nil }
            var transport: UInt32 = 0
            try? id.read(kAudioDevicePropertyTransportType, into: &transport)
            // Private aggregates (including Fader's own tap devices) are plumbing,
            // not user choices.
            guard transport != kAudioDeviceTransportTypeAggregate || !name.hasPrefix("Fader") else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, transport: transport)
        })

        autoSwitch(previousUIDs: previousUIDs, defaultUID: defaultUID)
        lastDefaultUID = defaultUID
        hasBaseline = true
    }

    // MARK: - Priority

    private func rank(_ uid: String) -> Int {
        priority.firstIndex(of: uid) ?? Int.max
    }

    /// Ranked devices in priority order first, unranked after, alphabetical
    /// within equal rank.
    private func sorted(_ list: [AudioDevice]) -> [AudioDevice] {
        list.sorted {
            let lhs = rank($0.uid)
            let rhs = rank($1.uid)
            if lhs != rhs { return lhs < rhs }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Priority-driven default switching, gated to explicit events so it
    /// never fights a manual choice:
    /// - exactly one ranked device appeared (hotplug, not a wake storm) and
    ///   it outranks the current default → switch to it;
    /// - the previous default disappeared → override macOS's fallback with
    ///   the best-ranked device still present.
    private func autoSwitch(previousUIDs: Set<String>, defaultUID: String?) {
        guard hasBaseline else { return }

        if let previous = lastDefaultUID, previousUIDs.contains(previous),
           !devices.contains(where: { $0.uid == previous }) {
            if let fallback = devices.filter({ rank($0.uid) != Int.max }).min(by: { rank($0.uid) < rank($1.uid) }),
               fallback.uid != defaultUID {
                Self.logger.info("Default device disappeared; switching to \(fallback.name)")
                setDefault(fallback)
            }
            return
        }

        let appeared = devices.filter { !previousUIDs.contains($0.uid) && rank($0.uid) != Int.max }
        guard appeared.count == 1, let candidate = appeared.first, let defaultUID,
              rank(candidate.uid) < rank(defaultUID)
        else { return }
        Self.logger.info("Higher-priority device connected; switching to \(candidate.name)")
        setDefault(candidate)
    }

    /// Records that the current default output is in use. Writes are throttled
    /// to one per hour per device — ample granularity for a 30-day window.
    private func stampDefaultDevice(uid: String?, now: Date = Date()) {
        guard let uid else { return }
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
