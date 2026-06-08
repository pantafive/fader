import CoreAudio
import Foundation
import Observation
import os

/// The heart of Fader: binds the process list to per-app volume state and
/// owns one ProcessTap per adjusted app. Apps at unity gain stay untouched —
/// no tap, no processing, bit-perfect native playback.
@MainActor
@Observable
final class MixerEngine {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "MixerEngine")

    let processMonitor = AudioProcessMonitor()
    let systemVolume = SystemVolumeController()
    let deviceMonitor = AudioDeviceMonitor()
    let inputVolume = SystemVolumeController(direction: .input)
    let inputDeviceMonitor = AudioDeviceMonitor(direction: .input)
    let bluetooth = BluetoothAudioMonitor()
    let multiOutput = MultiOutputController()

    /// Set when tap creation fails with a permission-shaped error.
    private(set) var needsAudioCapturePermission = false

    /// False until the first successful HAL contact; the UI shows a waiting
    /// state while the audio system is unreachable.
    private(set) var isStarted = false

    private(set) var volumes: [String: AppVolume] = [:]

    @ObservationIgnored private var taps: [String: ProcessTap] = [:]
    @ObservationIgnored private let store = VolumeStore()
    @ObservationIgnored private var deviceListener: HALListener?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var routingTask: Task<Void, Never>?
    @ObservationIgnored private var bluetoothRefreshTask: Task<Void, Never>?

    func start() {
        volumes = store.load()
        processMonitor.start()
        systemVolume.start()
        deviceMonitor.start()
        inputVolume.start()
        inputDeviceMonitor.start()
        multiOutput.start()
        bluetooth.refresh()

        // Rebuild taps when the default output device changes — each aggregate
        // is pinned to a concrete device UID.
        deviceListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in self?.rebuildAllTaps() }
        }

        observeApps()
        observeDevices()
        syncTaps()
        isStarted = true
    }

    func volume(for app: AudioApp) -> AppVolume {
        volumes[app.bundleID] ?? AppVolume()
    }

    func setVolume(_ value: Float, for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.volume = max(0, min(1, value))
        apply(entry, to: app)
    }

    func toggleMute(for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.isMuted.toggle()
        apply(entry, to: app)
    }

    /// Paired IOBluetooth peer of a HAL device, when one matches by MAC.
    func bluetoothPeer(for device: AudioDevice) -> BluetoothAudioDevice? {
        bluetooth.paired.first { device.matches(bluetoothID: $0.id) }
    }

    /// Connects Bluetooth headphones and routes output to them once CoreAudio
    /// picks the device up.
    func connectBluetooth(_ device: BluetoothAudioDevice) {
        bluetooth.connect(device) { [weak self] connected in
            self?.routeWhenAvailable(connected)
        }
    }

    /// The HAL device for a Bluetooth peer appears a moment after the link
    /// opens; its UID starts with the MAC address. Poll briefly, then route.
    /// A new connect cancels the previous poll so rapid reconnects don't race.
    private func routeWhenAvailable(_ device: BluetoothAudioDevice) {
        routingTask?.cancel()
        routingTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 16 {
                guard let self, !Task.isCancelled else { return }
                deviceMonitor.refresh()
                if let halDevice = deviceMonitor.devices.first(where: { $0.matches(bluetoothID: device.id) }) {
                    deviceMonitor.setDefault(halDevice)
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Adds a device to the active outputs, building the multi-output route
    /// on the first pairing.
    func pair(_ device: AudioDevice) {
        let current = deviceMonitor.devices.first { $0.id == deviceMonitor.defaultDeviceID }
        multiOutput.pair(device, currentDefault: current)
    }

    func unpair(_ device: AudioDevice) {
        multiOutput.remove(device)
    }

    /// Drops the tap for an app, restoring its native audio path.
    func reset(_ app: AudioApp) {
        volumes[app.bundleID] = nil
        store.save(volumes)
        if let tap = taps.removeValue(forKey: app.bundleID) {
            tap.invalidate()
        }
    }

    /// Smooths the volume jump when Fader exits. A tap mutes the app's native
    /// output and re-renders it attenuated, so destroying the tap restores the
    /// native output at full — an abrupt jump (and click) up from whatever
    /// level the app was held at. There is no per-app system volume to keep,
    /// so the app does return to full; ramping each tap to unity first and
    /// letting the IO proc render the ramp means the native output un-mutes at
    /// the level it is about to play, a smooth rise instead of a slam. Muted
    /// taps render silence and can't fade audibly, so they restore as-is.
    func fadeOutAndStop() {
        let fading = taps.values.filter { !$0.isMuted && $0.volume < 0.999 }
        if !fading.isEmpty {
            for tap in fading {
                tap.volume = 1.0
            }
            // ~5× the 30 ms gain ramp: long enough for the rendered level to
            // reach unity before teardown un-mutes the native output. Blocking
            // is fine here — this only runs from applicationWillTerminate, and
            // the IO proc rendering the ramp lives on its own queue.
            Thread.sleep(forTimeInterval: 0.15)
        }
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
    }

    // MARK: - Private

    private func observeApps() {
        // Re-sync taps whenever the app list changes (launch/quit).
        withObservationTracking {
            _ = processMonitor.apps
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncTaps()
                self?.observeApps()
            }
        }
    }

    private func observeDevices() {
        // A HAL device appearing or vanishing usually IS a Bluetooth event;
        // refresh the paired list so the disconnected section tracks reality.
        withObservationTracking {
            _ = deviceMonitor.devices
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBluetoothSoon()
                self.multiOutput.handleDevicesChanged(present: self.deviceMonitor.devices)
                self.observeDevices()
            }
        }
    }

    /// Twice: once now, once after IOBluetooth's connection state has had a
    /// moment to settle — it lags the HAL by a beat in both directions.
    private func refreshBluetoothSoon() {
        bluetooth.refresh()
        bluetoothRefreshTask?.cancel()
        bluetoothRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.bluetooth.refresh()
        }
    }

    private func apply(_ entry: AppVolume, to app: AudioApp) {
        volumes[app.bundleID] = entry
        scheduleSave()

        if let tap = taps[app.bundleID] {
            tap.volume = entry.volume
            tap.isMuted = entry.isMuted
        } else if !entry.isNeutral {
            createTap(for: app, entry: entry)
        }
    }

    /// Slider drags call apply per pixel; coalesce the UserDefaults write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            store.save(volumes)
        }
    }

    /// Ensures every non-neutral running app has a live tap covering its
    /// current process set, and every gone app's tap is released.
    private func syncTaps() {
        let running = Dictionary(uniqueKeysWithValues: processMonitor.apps.map { ($0.bundleID, $0) })

        for (bundleID, tap) in taps {
            guard let app = running[bundleID] else {
                tap.invalidate()
                taps[bundleID] = nil
                continue
            }
            // A browser that spawns a new media child needs the tap rebuilt —
            // the old one keeps muting only the processes it was born with.
            if tap.processObjectIDs != app.objectIDs {
                tap.invalidate()
                taps[bundleID] = nil
            }
        }

        for (bundleID, entry) in volumes where !entry.isNeutral {
            guard taps[bundleID] == nil, let app = running[bundleID] else { continue }
            createTap(for: app, entry: entry)
        }
    }

    private func createTap(for app: AudioApp, entry: AppVolume) {
        // Per-app taps are suspended while multi-output plays: a tap aggregate
        // pinned to another aggregate is unproven (the CLI probe's IO proc
        // never fired), and a silently dead tap would mute the app outright.
        // Saved volumes survive and re-apply once multi-output dissolves.
        guard !multiOutput.isActive else { return }

        let outputUID: String
        do {
            outputUID = try AudioObjectID.readDefaultOutputDevice().readDeviceUID()
        } catch {
            // Transient device churn (output switching), not a permission issue.
            Self.logger.error("Default device read failed: \(error.localizedDescription)")
            return
        }

        do {
            let tap = ProcessTap(processObjectIDs: app.objectIDs, volume: entry.volume, isMuted: entry.isMuted)
            try tap.activate(outputDeviceUID: outputUID)
            taps[app.bundleID] = tap
            needsAudioCapturePermission = false
        } catch {
            Self.logger.error("Tap failed for \(app.bundleID): \(error.localizedDescription)")
            // TCC denial surfaces as a tap creation failure; offer the user a way out.
            needsAudioCapturePermission = true
        }
    }

    private func rebuildAllTaps() {
        let bundleIDs = Array(taps.keys)
        for bundleID in bundleIDs {
            taps[bundleID]?.invalidate()
            taps[bundleID] = nil
        }
        syncTaps()
    }
}
