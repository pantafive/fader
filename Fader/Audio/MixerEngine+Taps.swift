import CoreAudio
import Foundation

extension MixerEngine {
    /// Nil while multi-output plays: a tap aggregate pinned to another
    /// aggregate is unproven (the CLI probe's IO proc never fired), and a
    /// silently dead tap would mute the app outright. Saved volumes survive
    /// and re-apply once multi-output dissolves.
    func makeTap(for app: AudioApp, entry: AppVolume, replacing old: ProcessTap?) throws -> ProcessTap? {
        guard !multiOutput.isActive else { return nil }
        let outputs = try resolvedOutputs(for: entry)
        // A routed app's loudness lives on its devices' own volume controls
        // (one slider per pinned device), so its tap renders transparent — the
        // app-level gain and mute apply only when it follows the default.
        let routed = !entry.outputDeviceUIDs.isEmpty
        let tap = ProcessTap(
            processObjectIDs: app.objectIDs,
            volume: routed ? 1.0 : entry.volume,
            isMuted: routed ? false : entry.isMuted
        )
        if old != nil { tap.rampInFromSilence() }
        try tap.activate(outputs: outputs)
        let bundleID = app.bundleID
        tap.onOutputResumed = { [weak self] in self?.processMonitor.refresh() }
        tap.onBroken = { [weak self] in self?.rebuildBrokenTap(bundleID) }
        tap.updatePlaybackState(isPlaying: app.isPlaying)
        return tap
    }

    /// Fades the replaced tap out under the new one's fade-in, then tears it
    /// down; the processes stay muted throughout because the new tap reads them.
    func retire(_ tap: ProcessTap) {
        tap.volume = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            tap.invalidate()
        }
    }

    /// Releasing restores the app's native output at full volume.
    func releaseTap(_ bundleID: String) {
        taps.removeValue(forKey: bundleID)?.invalidate()
        rebuildPendingSince[bundleID] = nil
    }

    func rebuildBrokenTap(_ bundleID: String) {
        rebuildPendingSince[bundleID] = rebuildPendingSince[bundleID] ?? .now
        syncTaps()
    }

    /// No HAL event is guaranteed to follow a failure — a steadily playing app
    /// never changes the process list — so retry on a timer instead.
    func scheduleTapRetry() {
        guard retryTask == nil else { return }
        tapFailures += 1
        let delay = TapRebuildPolicy.retryDelay(afterFailures: tapFailures)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            syncTaps()
        }
    }

    /// The devices an app's tap should play through: its pinned route when
    /// present, otherwise the system default. A pinned-but-absent device falls
    /// back to the default so the app stays audible until it returns — the
    /// stored route survives for when it does.
    func resolvedOutputs(for entry: AppVolume) throws -> [ProcessTap.Output] {
        let present = entry.outputDeviceUIDs.compactMap { uid in deviceMonitor.devices.first { $0.uid == uid } }
        // Clock leads: a Bluetooth clock drifts, so a wired/built-in member is
        // preferred to drive the aggregate, mirroring multi-output.
        guard let clock = MultiOutputPolicy.clock(among: present) else {
            let id = try AudioObjectID.readDefaultOutputDevice()
            return try [ProcessTap.Output(uid: id.readDeviceUID(), id: id)]
        }
        return ([clock] + present.filter { $0.uid != clock.uid })
            .map { ProcessTap.Output(uid: $0.uid, id: $0.id) }
    }
}
