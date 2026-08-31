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

    #if RENDER_SHOTS
        /// Render harness only: publish active members without creating an
        /// aggregate, so the paired-state screenshot has no HAL contact.
        func seedForRender(members: [Member]) {
            self.members = members
        }
    #endif

    func start() {
        adoptOrDestroyLeftover()
        installDefaultListener()
    }

    /// Public aggregates may survive an audio-service reset under a new object
    /// ID. Forget all cached HAL identities, then adopt the live aggregate only
    /// when it is still the default; otherwise fail safe to the system route.
    func recoverAfterServiceRestart() {
        aggregateID = .unknown
        members = []
        defaultListener = nil
        adoptOrDestroyLeftover()
        installDefaultListener()
    }

    private func installDefaultListener() {
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
        // A failed destroy leaves the ID tracked with no active members. Retry
        // opportunistically instead of forgetting a public aggregate forever.
        guard isActive else {
            if aggregateID.isValid {
                _ = prepareToDestroyAggregate(preferredFallback: present.first)
            }
            return
        }

        let oldDevices = members.map(\.device)
        let refreshed = MultiOutputPolicy.refreshed(members: oldDevices, present: present)
        guard refreshed.count == oldDevices.count else {
            let resolution = MultiOutputPolicy.resolution(survivors: refreshed)
            if case .dissolve(to: nil) = resolution {
                dissolve(to: present.first)
            } else {
                resolve(resolution)
            }
            return
        }

        // A device may disappear and re-publish under the same UID but a new
        // object ID (common across wake/reconnect). Recreate the aggregate and
        // its volume controllers rather than keeping dead HAL references.
        let idsChanged = zip(oldDevices, refreshed).contains { $0.id != $1.id }
        if idsChanged || !aggregateIsAlive {
            apply(refreshed)
        }
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
        guard aggregateID.isValid else { return }
        dissolve(to: members.first?.device)
    }

    // MARK: - Private

    private func apply(_ devices: [AudioDevice]) {
        guard let clock = MultiOutputPolicy.clock(among: devices) else { return }
        let previousMembers = members

        // Membership changes recreate the aggregate (mutating the sub-device
        // list in place loses the drift settings). Route to the clock device
        // first so destroying the current default can't strand the system on
        // an arbitrary fallback.
        guard prepareToDestroyAggregate(preferredFallback: clock) else { return }

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
        aggregateID = aggregate

        do {
            try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: aggregate)
        } catch {
            Self.logger.error("Failed to route to multi-output aggregate: \(error.localizedDescription)")
            members = []
            _ = destroyTrackedAggregate()
            // If destruction failed, aggregateID intentionally remains valid so
            // later device events, pair attempts, or shutdown can retry it.
            return
        }
        members = devices.map { device in
            Member(device: device, volume: volumeController(for: device, reusing: previousMembers))
        }
        Self.logger.info("Multi-output active: \(devices.map(\.name).joined(separator: " + "), privacy: .public)")
    }

    /// Reuses a surviving member's controller so its HAL listeners and
    /// published state carry over membership changes.
    private func volumeController(for device: AudioDevice, reusing previous: [Member]) -> DeviceVolumeController {
        previous.first { $0.device.uid == device.uid && $0.device.id == device.id }?.volume
            ?? DeviceVolumeController(deviceID: device.id)
    }

    private func dissolve(to device: AudioDevice?) {
        _ = prepareToDestroyAggregate(preferredFallback: device)
    }

    /// `apply` runs synchronously on the main actor, so by the time this
    /// queued listener task observes the default it already points at the
    /// (re)created aggregate — only genuinely external switches dissolve.
    private func dissolveIfRoutedAway() {
        guard aggregateID.isValid,
              let current = try? AudioObjectID.readDefaultOutputDevice(),
              current != aggregateID
        else { return }
        if isActive {
            Self.logger.info("Default output moved elsewhere; dissolving multi-output")
        }
        // The system already routes elsewhere, so no fallback write is needed.
        members = []
        _ = destroyTrackedAggregate()
    }

    /// A crash or kill can leave the public aggregate behind. If a previous
    /// run's aggregate is still the default, adopt it — the user's audio is
    /// flowing through it right now; otherwise clean it up.
    private func adoptOrDestroyLeftover() {
        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self),
              let leftover = ids.first(where: { (try? $0.readDeviceUID()) == Self.aggregateUID })
        else { return }

        aggregateID = leftover
        let isDefault = (try? AudioObjectID.readDefaultOutputDevice()) == leftover
        let devices = subDevices(of: leftover)
        guard isDefault, let devices, devices.count > 1 else {
            _ = prepareToDestroyAggregate(preferredFallback: devices?.first)
            return
        }
        members = devices.map { Member(device: $0, volume: DeviceVolumeController(deviceID: $0.id)) }
        Self.logger.info("Adopted multi-output aggregate from a previous run")
    }

    /// True only while the tracked aggregate still answers HAL's liveness
    /// property. UID presence alone cannot catch a dead aggregate after wake.
    private var aggregateIsAlive: Bool {
        guard aggregateID.isValid else { return false }
        var alive: UInt32 = 0
        guard (try? aggregateID.read(kAudioDevicePropertyDeviceIsAlive, into: &alive)) != nil else { return false }
        return alive != 0
    }

    /// Routes away before deleting a tracked public aggregate. If any safety
    /// step fails, the ID remains tracked for a later retry; the controller
    /// never claims cleanup succeeded when HAL said otherwise.
    @discardableResult
    private func prepareToDestroyAggregate(preferredFallback: AudioDevice?) -> Bool {
        guard aggregateID.isValid else {
            members = []
            return true
        }

        guard let current = try? AudioObjectID.readDefaultOutputDevice() else {
            Self.logger.error("Cannot safely destroy multi-output: failed to read the default output")
            return false
        }
        if current == aggregateID {
            guard let fallback = validFallback(preferredFallback) ?? firstAvailableOutput() else {
                Self.logger.error("Cannot safely destroy multi-output: no fallback output is available")
                return false
            }
            do {
                try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: fallback.id)
            } catch {
                Self.logger
                    .error("Cannot safely destroy multi-output: fallback routing failed: \(error.localizedDescription)")
                return false
            }
        }

        members = []
        return destroyTrackedAggregate()
    }

    private func validFallback(_ device: AudioDevice?) -> AudioDevice? {
        guard let device,
              device.id != aggregateID,
              device.id.channelCount(scope: kAudioDevicePropertyScopeOutput) > 0,
              let current = AudioDevice(id: device.id), !current.isFaderPlumbing
        else { return nil }
        return current
    }

    private func firstAvailableOutput() -> AudioDevice? {
        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        else { return nil }
        return ids.lazy.compactMap { id -> AudioDevice? in
            guard id != self.aggregateID,
                  id.channelCount(scope: kAudioDevicePropertyScopeOutput) > 0,
                  let device = AudioDevice(id: id), !device.isFaderPlumbing
            else { return nil }
            return device
        }.first
    }

    @discardableResult
    private func destroyTrackedAggregate() -> Bool {
        guard aggregateID.isValid else { return true }
        let doomed = aggregateID
        let status = AudioHardwareDestroyAggregateDevice(doomed)
        guard status == noErr else {
            Self.logger.error("Failed to destroy multi-output aggregate \(doomed): OSStatus \(status)")
            return false
        }
        aggregateID = .unknown
        return true
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
