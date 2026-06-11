import AppKit
import CoreAudio
import OSLog
import Sparkle

/// Sparkle wrapper. Background checks are always on; the "Update
/// Automatically" toggle controls whether a found update is also downloaded
/// and installed silently. The Homebrew cask declares `auto_updates true`,
/// so `brew upgrade` leaves the bundle to Sparkle — both install channels
/// share this one flow.
///
/// With auto-update off, background finds stay gentle reminders: they set
/// `availableVersion`, which lights the popover row and retitles the menu
/// item; Sparkle's own windows appear only for a user-initiated check.
/// With auto-update on, the staged update relaunches the app right away —
/// but only while nobody would notice: the app in the background and no
/// audio playing (the restart drops process taps for a moment, so a movie
/// mid-playback would blip to full per-app volume). Otherwise the row and
/// menu flip to "Restart to Update" and install-on-quit remains the
/// backstop. An update relaunch skips the multi-output teardown so the
/// next instance adopts the still-default aggregate — audio keeps flowing
/// through the restart.
@MainActor
@Observable
final class UpdateController {
    /// Version found by the last check, nil when current. Drives the popover
    /// row and the context-menu title.
    private(set) var availableVersion: String?

    /// Version downloaded and staged for install. Invoking `checkForUpdates`
    /// in this state relaunches into it.
    private(set) var stagedVersion: String?

    /// True while the app is terminating to relaunch into a staged update.
    /// AppDelegate then leaves the multi-output aggregate alive for the next
    /// instance to adopt instead of dissolving it.
    private(set) static var isRelaunchingForUpdate = false

    static let log = Logger(subsystem: "dev.pantafive.fader", category: "updates")

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let bridge = SparkleBridge()
    @ObservationIgnored private var relaunchHandler: (() -> Void)?

    // Event sources that re-open a quiet window for a held-back staged
    // update. Armed only while one waits, torn down on relaunch.
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var runningListener: HALListener?
    @ObservationIgnored private var defaultDeviceListener: HALListener?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
        bridge.owner = self

        // Checks are forced on every launch: no menu item controls them
        // anymore, and a stale `false` left by the retired "Check
        // Automatically" toggle would otherwise kill both auto-update and
        // the passive banner with no UI to recover. Setting the property
        // (rather than SUEnableAutomaticChecks in Info.plist) also skips
        // Sparkle's first-run permission modal. Downloads seed default-on
        // once and stay a preference the menu toggle can flip off.
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") == nil {
            updater.automaticallyDownloadsUpdates = true
        }
        try? updater.start()
    }

    /// The menu toggle: download and install updates without asking.
    /// Checking stays on either way — off just means the gentle-reminder
    /// flow where the user clicks to start Sparkle's interactive update.
    var automaticallyUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Menu and popover-row action. With an update staged, relaunch into it;
    /// otherwise run Sparkle's standard interactive flow.
    func checkForUpdates() {
        if relaunchHandler != nil {
            relaunch()
        } else {
            controller.checkForUpdates(nil)
        }
    }

    // MARK: - Bridge callbacks (main thread, re-isolated)

    fileprivate func updateFound(version: String) {
        Self.log.info("update available: \(version, privacy: .public)")
        availableVersion = version
    }

    /// The feed answered and nothing newer is installable. A failed check
    /// (feed unreachable, bad XML) deliberately does NOT clear a previously
    /// found version — a transient failure is not evidence the update
    /// disappeared.
    fileprivate func upToDate() {
        Self.log.info("up to date")
        availableVersion = nil
    }

    /// The update is downloaded and staged. Install it the moment it would go
    /// unnoticed — app in the background, output device idle. If that moment
    /// isn't here yet, wait for it (see `armQuietRelaunch`) rather than
    /// stranding the user on a manual click; the "Restart to Update" row and
    /// install-on-quit remain as the backstop either way.
    fileprivate func updateStaged(version: String, relaunch: @escaping () -> Void) {
        Self.log.info("update staged: \(version, privacy: .public)")
        relaunchHandler = relaunch
        stagedVersion = version
        if !tryQuietRelaunch() { armQuietRelaunch() }
    }

    /// Silently install the staged update iff nobody would notice. Returns
    /// true once it commits to relaunching, so the caller knows to stop
    /// waiting. A relaunch mid-playback would blip per-app taps to unity, so
    /// the audio guard is non-negotiable.
    @discardableResult
    private func tryQuietRelaunch() -> Bool {
        guard relaunchHandler != nil, !Self.isRelaunchingForUpdate else { return false }
        guard !NSApp.isActive, !Self.audioIsPlaying() else { return false }
        relaunch()
        return true
    }

    /// The quiet moment wasn't here when the update staged. Re-check on the
    /// two events that can open one — the app resigning active (popover
    /// dismissed, user switched away) and the output device falling idle
    /// (playback or a call ended) — for an instant reaction when they fire.
    /// Those HAL/AppKit signals are unproven on this OS (the sibling
    /// per-process running property is a documented non-deliverer), so a
    /// low-frequency timer backs them so correctness never rests on them.
    /// All three exist only while an update waits and die on relaunch —
    /// nothing runs in steady state.
    private func armQuietRelaunch() {
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.tryQuietRelaunch() }
            }
        }
        armRunningListener()
        // The default output can switch while we wait; re-arm onto the new
        // device and re-check — it may already be idle.
        defaultDeviceListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in
                self?.armRunningListener()
                self?.tryQuietRelaunch()
            }
        }
        if retryTask == nil {
            retryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled else { break }
                    if tryQuietRelaunch() { break }
                }
            }
        }
    }

    private func armRunningListener() {
        runningListener = (try? AudioObjectID.readDefaultOutputDevice()).map { device in
            device.listen(kAudioDevicePropertyDeviceIsRunningSomewhere) {
                Task { @MainActor [weak self] in self?.tryQuietRelaunch() }
            }
        }
    }

    private func relaunch() {
        Self.isRelaunchingForUpdate = true
        teardownQuietWatch()
        relaunchHandler?()
    }

    private func teardownQuietWatch() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        runningListener = nil
        defaultDeviceListener = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private static func audioIsPlaying() -> Bool {
        guard let device = try? AudioObjectID.readDefaultOutputDevice() else { return false }
        return device.readDeviceIsRunningSomewhere()
    }
}

/// Holds the ObjC delegate conformances so UpdateController stays a plain
/// observable class. Sparkle calls both delegates on the main thread:
/// SPUUpdaterDelegate is MainActor-annotated upstream; the user-driver
/// protocol isn't, so its conformance is declared isolated explicitly —
/// that rests on SPUStandardUserDriver's main-thread promise, which the
/// compiler can't check across the ObjC call-in. Swapping in a custom user
/// driver that dispatches off-main would make this conformance unsound.
@MainActor
private final class SparkleBridge: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    weak var owner: UpdateController?

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.updateFound(version: item.displayVersionString)
    }

    /// Only fires when the feed answered and held nothing installable;
    /// failed checks go to didAbortWithError instead.
    func updaterDidNotFindUpdate(_: SPUUpdater, error _: Error) {
        owner?.upToDate()
    }

    /// Fires for every aborted cycle, including the benign outcomes already
    /// handled elsewhere — filter those, log the genuine failures.
    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain {
            let benign: [SUError] = [.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError]
            if benign.contains(where: { Int($0.rawValue) == nsError.code }) { return }
        }
        UpdateController.log.error("update cycle failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Fires when the automatic driver has silently downloaded and staged an
    /// update. Returning true takes over the install reminder; the block
    /// installs and relaunches without UI and may be invoked again if a
    /// termination request gets cancelled.
    func updater(
        _: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        owner?.updateStaged(version: item.displayVersionString, relaunch: immediateInstallHandler)
        return true
    }

    // MARK: - Gentle reminders

    /// Scheduled finds light the popover row instead of Sparkle popping a
    /// window over whatever the user is doing.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem, andInImmediateFocus _: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _: Bool, forUpdate update: SUAppcastItem, state _: SPUUserUpdateState
    ) {
        owner?.updateFound(version: update.displayVersionString)
    }
}
