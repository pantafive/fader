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

    /// The update is downloaded and staged. Relaunch into it right away
    /// while nobody is looking — app in the background, output device idle.
    /// Otherwise surface "Restart to Update" and let the user pick the
    /// moment; Sparkle installs on quit regardless.
    fileprivate func updateStaged(version: String, relaunch: @escaping () -> Void) {
        Self.log.info("update staged: \(version, privacy: .public)")
        relaunchHandler = relaunch
        stagedVersion = version
        if !NSApp.isActive, !Self.audioIsPlaying() {
            self.relaunch()
        }
    }

    private func relaunch() {
        Self.isRelaunchingForUpdate = true
        relaunchHandler?()
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
