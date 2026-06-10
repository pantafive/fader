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
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    #if RENDER_SHOTS
        /// Render harness only: publish a demo app list without any HAL contact.
        func seedForRender(apps: [AudioApp]) {
            self.apps = apps
        }
    #endif

    func start() {
        guard pollTask == nil else { return } // idempotent: a second call must not double-listen
        // List changes (process appeared / exited) arrive as HAL notifications.
        listListener = AudioObjectID.system.listen(kAudioHardwarePropertyProcessObjectList) {
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        // Per-process IsRunningOutput flips do NOT arrive in practice
        // (observed on macOS 26), so the playing state is polled. Reading the
        // flags of a few dozen process objects costs microseconds.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Generous tolerance lets the kernel coalesce the wakeup with
                // other timers — playing-state freshness doesn't need precision.
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
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

        struct Group {
            let app: NSRunningApplication
            var objects: [AudioObjectID] = []
            var playing = false
            var recording = false
        }
        var groups: [pid_t: Group] = [:]

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

            let key = running.processIdentifier
            var group = groups[key] ?? Group(app: running)
            group.objects.append(objectID)
            group.playing = group.playing || objectID.readProcessIsRunningOutput()
            group.recording = group.recording || objectID.readProcessIsRunningInput()
            groups[key] = group
        }

        var nextApps = groups.compactMap { pid, group -> AudioApp? in
            // Regular apps always; agents and helpers only while they actually
            // play or record — keeps Control Center, Siri, and GPU helpers out
            // without dropping background recorders (meeting helpers).
            guard group.app.activationPolicy == .regular || group.playing || group.recording
            else { return nil }
            return AudioApp(
                id: pid,
                bundleID: group.app.bundleIdentifier ?? "",
                name: group.app.localizedName ?? group.app.bundleIdentifier ?? "pid \(pid)",
                objectIDs: group.objects.sorted(),
                isPlaying: group.playing,
                isRecording: group.recording
            )
        }

        // Playing apps first, then alphabetical; stable for equal keys.
        nextApps.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if nextApps != apps {
            apps = nextApps
            let names = nextApps.map { "\($0.name)\($0.isPlaying ? "*" : "")" }.joined(separator: ", ")
            // App names stay redacted in the unified log (default .private).
            Self.logger.info("Apps: \(nextApps.count)/\(objectIDs.count) HAL processes — \(names)")
        }
    }

    // MARK: - Responsible process lookup

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` maps helper processes to
    /// the app that spawned them — the same attribution TCC uses. Private SPI:
    /// not in any public header, but stable since macOS 10.14 and widely used
    /// in open-source tools. If it ever disappears, the `?? pid` fallback
    /// degrades gracefully to per-helper attribution (browser audio shows as
    /// its helper process instead of the browser).
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
