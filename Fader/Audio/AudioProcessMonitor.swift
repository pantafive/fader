import AppKit
import CoreAudio
import Observation
import os

/// Watches the HAL's audio process list and publishes the running apps
/// that can play sound. Helper processes (browser media children, Electron
/// renderers) group under their responsible application.
@MainActor
@Observable
final class AudioProcessMonitor {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "AudioProcessMonitor")

    private(set) var apps: [AudioApp] = []

    @ObservationIgnored private var listListener: HALListener?
    @ObservationIgnored private var outputListeners: [AudioObjectID: HALListener] = [:]
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func start() {
        listListener = AudioObjectID.system.listen(kAudioHardwarePropertyProcessObjectList) {
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        // The HAL reliably notifies about list changes but, in practice, not
        // about per-process IsRunningOutput flips — poll those. Reading the
        // flags of a few dozen process objects costs microseconds.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
        refresh()
    }

    deinit {
        pollTask?.cancel()
        pendingRefresh?.cancel()
    }

    /// Coalesces listener bursts: HAL fires once per process and once per
    /// output-state flip, often a dozen times within a few milliseconds.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard let objectIDs = try? AudioObjectID.readProcessList() else {
            Self.logger.error("Failed to read HAL process list")
            return
        }

        var groups: [pid_t: (app: NSRunningApplication, objects: [AudioObjectID], playing: Bool)] = [:]
        var nextOutputListeners: [AudioObjectID: HALListener] = [:]

        for objectID in objectIDs {
            guard let pid = try? objectID.readProcessPID() else { continue }

            // Helper processes answer to the app the user knows; a browser tab's
            // audio belongs to the browser.
            let ownerPID = Self.responsiblePID(for: pid)
            guard let running = NSRunningApplication(processIdentifier: ownerPID)
                ?? NSRunningApplication(processIdentifier: pid),
                let bundleID = running.bundleIdentifier,
                bundleID != Bundle.main.bundleIdentifier
            else { continue }

            let isPlaying = objectID.readProcessIsRunningOutput()
            let key = running.processIdentifier
            groups[key, default: (running, [], false)].objects.append(objectID)
            groups[key]!.playing = groups[key]!.playing || isPlaying

            // Re-rank rows the moment a process starts or stops playing.
            nextOutputListeners[objectID] = outputListeners[objectID]
                ?? objectID.listen(kAudioProcessPropertyIsRunningOutput) {
                    Task { @MainActor [weak self] in self?.scheduleRefresh() }
                }
        }

        var nextApps = groups.compactMap { pid, group -> AudioApp? in
            // Regular apps always; agents and helpers only while they actually
            // play — keeps Control Center, Siri, and GPU helpers out.
            guard group.app.activationPolicy == .regular || group.playing else { return nil }
            return AudioApp(
                id: pid,
                bundleID: group.app.bundleIdentifier ?? "",
                name: group.app.localizedName ?? group.app.bundleIdentifier ?? "pid \(pid)",
                objectIDs: group.objects.sorted(),
                isPlaying: group.playing
            )
        }

        // Playing apps first, then alphabetical; stable for equal keys.
        nextApps.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        outputListeners = nextOutputListeners
        if nextApps != apps {
            apps = nextApps
            let names = nextApps.map { "\($0.name)\($0.isPlaying ? "*" : "")" }.joined(separator: ", ")
            Self.logger.info("Apps: \(nextApps.count)/\(objectIDs.count) HAL processes — \(names, privacy: .public)")
        }
    }

    // MARK: - Responsible process lookup

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` maps helper processes to
    /// the app that spawned them — the same attribution TCC uses. Not in any
    /// public header, but stable since macOS 10.14 and widely relied upon.
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsiblePIDFunction else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }
}
