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

    @ObservationIgnored var taps: [String: ProcessTap] = [:]
    /// One volume control per pinned-and-present device, keyed by UID — each
    /// routed output gets its own slider, like multi-output members.
    @ObservationIgnored private var routeVolumes: [String: DeviceVolumeController] = [:]
    @ObservationIgnored private let store = VolumeStore()
    @ObservationIgnored private var deviceListener: HALListener?
    @ObservationIgnored private var serviceRestartListener: HALListener?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Taps that stopped playing where they should, with when that was found.
    @ObservationIgnored var rebuildPendingSince: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var tapFailures = 0
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored var routingTask: Task<Void, Never>?
    @ObservationIgnored var bluetoothRefreshTask: Task<Void, Never>?
    @ObservationIgnored var wakeResyncTask: Task<Void, Never>?
    @ObservationIgnored private var powerMonitor: AudioPowerMonitor?

    #if RENDER_SHOTS
        /// Render harness only: mark the engine started and publish per-app
        /// volumes plus the per-device controllers backing routed-app sliders;
        /// callers seed the child monitors directly. No HAL contact.
        func seedForRender(volumes: [String: AppVolume],
                           routeVolumes: [String: DeviceVolumeController] = [:]) {
            self.volumes = volumes
            self.routeVolumes = routeVolumes
            isStarted = true
        }
    #endif

    func start() {
        volumes = store.load()
        processMonitor.start()
        systemVolume.start()
        deviceMonitor.start()
        inputVolume.start()
        inputDeviceMonitor.start()
        multiOutput.start()
        bluetooth.refresh()

        installHALListeners()

        observeApps()
        observeDevices()
        powerMonitor = AudioPowerMonitor(
            onSleep: { [weak self] in self?.prepareForSleep() },
            onWake: { [weak self] in self?.recoverAfterWake() }
        )
        powerMonitor?.start()
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
        releaseTap(app.bundleID)
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

    func discardHALBoundState() {
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        rebuildPendingSince.removeAll()
        routeVolumes.removeAll()
    }

    func installHALListeners() {
        // Rebuild taps when the default output device changes — each aggregate
        // is pinned to a concrete device UID.
        deviceListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in self?.reconcileTapRouting() }
        }
        serviceRestartListener = AudioObjectID.system.listen(kAudioHardwarePropertyServiceRestarted) {
            Task { @MainActor [weak self] in self?.recoverAfterAudioServiceRestart() }
        }
    }

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
                self.reconcileTapRouting()
                self.observeDevices()
            }
        }
    }

    private func apply(_ entry: AppVolume, to app: AudioApp) {
        volumes[app.bundleID] = entry
        scheduleSave()

        if let tap = taps[app.bundleID] {
            tap.volume = entry.volume
            tap.isMuted = entry.isMuted
        } else if !entry.isNeutral {
            installTap(for: app, entry: entry)
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
    func syncTaps() {
        let apps = AudioApp.coalescedByBundleID(processMonitor.apps)
        let running = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })

        for (bundleID, tap) in taps {
            guard let app = running[bundleID], let entry = volumes[bundleID] else {
                releaseTap(bundleID)
                continue
            }
            // A browser that spawns a new media child needs the tap rebuilt —
            // the old one keeps muting only the processes it was born with.
            if tap.processObjectIDs != app.objectIDs || rebuildPendingSince[bundleID] != nil {
                installTap(for: app, entry: entry)
            } else {
                tap.updatePlaybackState(isPlaying: app.isPlaying)
            }
        }
        for (bundleID, entry) in volumes where !entry.isNeutral {
            guard taps[bundleID] == nil, let app = running[bundleID] else { continue }
            installTap(for: app, entry: entry)
        }
        syncRouteVolumes()
    }

    /// Keeps one DeviceVolumeController alive per pinned-and-present device,
    /// dropping controllers for devices no longer pinned or gone from the HAL.
    /// Rebuilt whenever routes or the device list change.
    private func syncRouteVolumes() {
        let pinned = Set(volumes.values.flatMap(\.outputDeviceUIDs))
            .filter { uid in deviceMonitor.devices.contains { $0.uid == uid } }
        for uid in routeVolumes.keys where !pinned.contains(uid) {
            routeVolumes[uid] = nil
        }
        for uid in pinned where routeVolumes[uid] == nil {
            guard let device = deviceMonitor.devices.first(where: { $0.uid == uid }) else { continue }
            routeVolumes[uid] = DeviceVolumeController(deviceID: device.id)
        }
    }

    /// Make-before-break: the replacement starts before the old tap goes, so
    /// the app is never left on its native output at full volume in between.
    /// A failed replacement leaves a working old tap running; a broken one
    /// holds the app silent while retries run, up to TapRebuildPolicy's limit.
    private func installTap(for app: AudioApp, entry: AppVolume) {
        let bundleID = app.bundleID
        let old = taps[bundleID]
        do {
            guard let tap = try makeTap(for: app, entry: entry, replacing: old) else {
                releaseTap(bundleID)
                return
            }
            taps[bundleID] = tap
            rebuildPendingSince[bundleID] = nil
            tapFailures = 0
            needsAudioCapturePermission = false
            if let old { retire(old) }
        } catch {
            Self.logger.error("Tap failed for \(bundleID): \(error.localizedDescription)")
            if let halError = error as? HALError, halError.isPermissionDenied {
                needsAudioCapturePermission = true
                releaseTap(bundleID)
                return
            }
            scheduleTapRetry()
            // A tap that still renders keeps attenuating the processes it has;
            // only one that can't play anymore needs holding silent.
            guard let old, old.isHeld || !old.isAlive else { return }
            let since = rebuildPendingSince[bundleID] ?? .now
            switch TapRebuildPolicy.brokenTap(failingSince: since, now: .now) {
            case .hold:
                rebuildPendingSince[bundleID] = since
                old.holdSilent()
            case .release:
                releaseTap(bundleID)
            }
        }
    }

    /// Rebuilds only the taps that no longer play where they should, so
    /// unrelated apps don't blip. Stale = resolved targets changed (object IDs
    /// too — devices re-publish under an old UID), aggregate died, or resolve
    /// failed; a wedged tap keeps its app muted until its replacement runs.
    func reconcileTapRouting() {
        for (bundleID, tap) in taps {
            guard let entry = volumes[bundleID] else { continue }
            if let desired = try? resolvedOutputs(for: entry),
               desired == tap.activatedOutputs, tap.isAlive { continue }
            rebuildPendingSince[bundleID] = rebuildPendingSince[bundleID] ?? .now
        }
        syncTaps()
    }

    private func rebuildTap(for app: AudioApp, entry: AppVolume) {
        if entry.isNeutral {
            releaseTap(app.bundleID)
        } else {
            installTap(for: app, entry: entry)
        }
        syncRouteVolumes()
    }
}

// MARK: - Per-app routing

extension MixerEngine {
    /// The UIDs an app is pinned to, present or not — drives the route chips.
    func routeUIDs(for app: AudioApp) -> [String] {
        volumes[app.bundleID]?.outputDeviceUIDs ?? []
    }

    /// Name of a pinned device by UID, when it is still present.
    func routeDeviceName(forUID uid: String) -> String? {
        deviceMonitor.devices.first { $0.uid == uid }?.name
    }

    /// The volume control backing a pinned device's own slider, if present.
    func routeVolume(forUID uid: String) -> (any VolumeControlling)? {
        routeVolumes[uid]
    }

    /// Pins an app's audio to another output device, on top of any already
    /// pinned. Routing forces a tap even at unity gain (the tap IS the route),
    /// so the tap is rebuilt to fan its aggregate out to the new device set.
    func route(_ app: AudioApp, to device: AudioDevice) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        guard !entry.outputDeviceUIDs.contains(device.uid) else { return }
        entry.outputDeviceUIDs.append(device.uid)
        volumes[app.bundleID] = entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    /// Drops one pinned device. The app keeps playing on whatever remains, and
    /// returns to the default once the last pin is gone.
    func unroute(_ app: AudioApp, from uid: String) {
        guard var entry = volumes[app.bundleID], entry.outputDeviceUIDs.contains(uid) else { return }
        entry.outputDeviceUIDs.removeAll { $0 == uid }
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    /// Clears every route, returning the app to the default output. Drops the
    /// tap when nothing else (volume or mute) keeps the app non-neutral.
    func clearRoute(for app: AudioApp) {
        guard var entry = volumes[app.bundleID], !entry.outputDeviceUIDs.isEmpty else { return }
        entry.outputDeviceUIDs.removeAll()
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }
}
