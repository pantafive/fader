import AudioToolbox
import CoreAudio
import Observation
import os

/// Plays to several outputs at once: a public stacked aggregate device (what
/// Audio MIDI Setup calls a Multi-Output Device) wraps the chosen physical
/// devices and becomes the system default. Probed live 2026-06-06: the
/// aggregate accepts the default-output role, and each sub-device's
/// VirtualMainVolume stays independently writable inside it.
@MainActor
@Observable
final class MultiOutputController {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "MultiOutput")

    /// Fixed UID: findable across restarts, at most one ever exists.
    static let aggregateUID = "dev.pantafive.fader.multi-output"
    /// The plumbing prefix keeps it out of AudioDeviceMonitor's device list.
    static let aggregateName = "\(AudioDevice.plumbingNamePrefix) Multi-Output"

    struct Member: Identifiable {
        let device: AudioDevice
        let volume: DeviceVolumeController
        var id: String { device.uid }
    }

    /// Active outputs; empty whenever multi-output is off.
    private(set) var members: [Member] = []
    var isActive: Bool { !members.isEmpty }

    @ObservationIgnored private var aggregateID = AudioObjectID.unknown
    @ObservationIgnored private var defaultListener: HALListener?

    func start() {
        adoptOrDestroyLeftover()
        // Output switched elsewhere (Control Center, Sound settings, a device
        // row click) means the aggregate left the audio path — dissolve.
        defaultListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in self?.dissolveIfRoutedAway() }
        }
    }

    /// Adds a device to the active outputs. The first pairing folds the
    /// current default in as the founding member.
    func pair(_ device: AudioDevice, currentDefault: AudioDevice?) {
        guard !members.contains(where: { $0.device.uid == device.uid }) else { return }
        var devices = members.map(\.device)
        if devices.isEmpty {
            guard let currentDefault, currentDefault.uid != device.uid else { return }
            devices = [currentDefault]
        }
        devices.append(device)
        apply(devices)
    }

    func remove(_ device: AudioDevice) {
        guard members.contains(where: { $0.device.uid == device.uid }) else { return }
        let rest = members.map(\.device).filter { $0.uid != device.uid }
        resolve(MultiOutputPolicy.resolution(survivors: rest))
    }

    /// Members whose HAL device vanished (Bluetooth dropped) leave; a single
    /// survivor means multi-output is over and it becomes the plain default.
    func handleDevicesChanged(present: [AudioDevice]) {
        guard isActive else { return }
        let presentUIDs = Set(present.map(\.uid))
        let alive = members.map(\.device).filter { presentUIDs.contains($0.uid) }
        guard alive.count < members.count else { return }
        resolve(MultiOutputPolicy.resolution(survivors: alive))
    }

    private func resolve(_ resolution: MultiOutputPolicy.Resolution) {
        switch resolution {
        case let .reapply(devices): apply(devices)
        case let .dissolve(to: device): dissolve(to: device)
        }
    }

    /// Quit teardown: route back to a real device and remove the aggregate —
    /// a leftover public aggregate would haunt Sound settings.
    func shutdown() {
        guard isActive else { return }
        dissolve(to: members.first?.device)
    }

    // MARK: - Private

    private func apply(_ devices: [AudioDevice]) {
        guard let clock = MultiOutputPolicy.clock(among: devices) else { return }

        // Membership changes recreate the aggregate (mutating the sub-device
        // list in place loses the drift settings). Route to the clock device
        // first so destroying the current default can't strand the system on
        // an arbitrary fallback.
        if aggregateID.isValid {
            try? AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: clock.id)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: Self.aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceClockDeviceKey: clock.uid,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceSubDeviceListKey: devices.map {
                [kAudioSubDeviceUIDKey: $0.uid, kAudioSubDeviceDriftCompensationKey: $0.uid != clock.uid]
            },
        ]
        var aggregate = AudioObjectID.unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else {
            Self.logger.error("Failed to create multi-output aggregate: OSStatus \(status)")
            members = []
            return
        }

        do {
            try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: aggregate)
        } catch {
            Self.logger.error("Failed to route to multi-output aggregate: \(error.localizedDescription)")
            AudioHardwareDestroyAggregateDevice(aggregate)
            members = []
            return
        }
        aggregateID = aggregate
        members = devices.map { device in
            Member(device: device, volume: volumeController(for: device))
        }
        Self.logger.info("Multi-output active: \(devices.map(\.name).joined(separator: " + "), privacy: .public)")
    }

    /// Reuses a surviving member's controller so its HAL listeners and
    /// published state carry over membership changes.
    private func volumeController(for device: AudioDevice) -> DeviceVolumeController {
        members.first { $0.device.uid == device.uid }?.volume ?? DeviceVolumeController(deviceID: device.id)
    }

    private func dissolve(to device: AudioDevice?) {
        if let device {
            try? AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: device.id)
        }
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        members = []
    }

    /// `apply` runs synchronously on the main actor, so by the time this
    /// queued listener task observes the default it already points at the
    /// (re)created aggregate — only genuinely external switches dissolve.
    private func dissolveIfRoutedAway() {
        guard isActive,
              let current = try? AudioObjectID.readDefaultOutputDevice(),
              current != aggregateID
        else { return }
        Self.logger.info("Default output moved elsewhere; dissolving multi-output")
        dissolve(to: nil)
    }

    /// A crash or kill can leave the public aggregate behind. If a previous
    /// run's aggregate is still the default, adopt it — the user's audio is
    /// flowing through it right now; otherwise clean it up.
    private func adoptOrDestroyLeftover() {
        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self),
              let leftover = ids.first(where: { (try? $0.readDeviceUID()) == Self.aggregateUID })
        else { return }

        let isDefault = (try? AudioObjectID.readDefaultOutputDevice()) == leftover
        guard isDefault, let devices = subDevices(of: leftover), devices.count > 1 else {
            AudioHardwareDestroyAggregateDevice(leftover)
            return
        }
        aggregateID = leftover
        members = devices.map { Member(device: $0, volume: DeviceVolumeController(deviceID: $0.id)) }
        Self.logger.info("Adopted multi-output aggregate from a previous run")
    }

    private func subDevices(of aggregate: AudioObjectID) -> [AudioDevice]? {
        var list: CFArray = [CFString]() as CFArray
        guard (try? aggregate.read(kAudioAggregateDevicePropertyFullSubDeviceList, into: &list)) != nil,
              let uids = list as? [String],
              let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        else { return nil }
        let byUID = Dictionary(ids.compactMap { id in (try? id.readDeviceUID()).map { ($0, id) } },
                               uniquingKeysWith: { first, _ in first })
        return uids.compactMap { uid in byUID[uid].flatMap { AudioDevice(id: $0) } }
    }
}
