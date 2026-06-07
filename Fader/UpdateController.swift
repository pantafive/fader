import AppKit
import OSLog
import Sparkle

/// Sparkle wrapper plus the install-channel fork. A dmg install gets the
/// standard download-install-relaunch flow; a Homebrew install (Caskroom
/// receipt on disk) only gets told an update exists — Sparkle swapping a
/// brew-owned bundle would desync the cask receipt and the next
/// `brew upgrade` would fight the already-new app.
///
/// Background checks stay silent (gentle reminders): finding an update sets
/// `availableVersion`, which lights the popover row and retitles the menu
/// item; Sparkle's own windows appear only for a user-initiated check.
@MainActor
@Observable
final class UpdateController {
    /// Version found by the last check, nil when current. Drives the popover
    /// row and the context-menu title.
    private(set) var availableVersion: String?

    let isHomebrewInstall: Bool

    static let homebrewCommand = "brew upgrade --cask fader"

    static let log = Logger(subsystem: "dev.pantafive.fader", category: "updates")

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let bridge = SparkleBridge()
    /// A menu-initiated check on the brew channel reports through an alert;
    /// background checks land on the popover row only.
    @ObservationIgnored private var manualBrewCheck = false

    init() {
        isHomebrewInstall = Self.homebrewOwnsThisBuild()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
        bridge.owner = self

        // Default-on without Sparkle's first-run permission modal: seed the
        // user default once. Unlike SUEnableAutomaticChecks in Info.plist,
        // this stays a preference the menu toggle can flip off.
        let updater = controller.updater
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            updater.automaticallyChecksForUpdates = true
        }
        try? updater.start()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The Caskroom directory alone is stale evidence: it survives a switch
    /// to the dmg until `brew uninstall`, which would strand that user on
    /// manual update prompts forever. Brew names the version subdirectory
    /// after the cask version (== marketing version), so only a subdirectory
    /// matching the running build proves brew owns this copy; a dmg update
    /// past the cask gets the standard Sparkle flow back.
    private static func homebrewOwnsThisBuild() -> Bool {
        let version = Bundle.main.shortVersion
        return ["/opt/homebrew/Caskroom/fader", "/usr/local/Caskroom/fader"]
            .contains { FileManager.default.fileExists(atPath: "\($0)/\(version)") }
    }

    /// Menu and popover-row action. Dmg: Sparkle's standard interactive flow.
    /// Brew: a UI-less probe whose outcome comes back as an alert.
    func checkForUpdates() {
        guard isHomebrewInstall else {
            controller.checkForUpdates(nil)
            return
        }
        if let availableVersion {
            showBrewAlert(version: availableVersion)
        } else {
            manualBrewCheck = true
            controller.updater.checkForUpdateInformation()
        }
    }

    static func copyHomebrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(homebrewCommand, forType: .string)
    }

    // MARK: - Bridge callbacks (main thread, re-isolated)

    fileprivate func updateFound(version: String) {
        Self.log.info("update available: \(version, privacy: .public)")
        availableVersion = version
        if manualBrewCheck {
            manualBrewCheck = false
            showBrewAlert(version: version)
        }
    }

    /// The feed answered and nothing newer is installable.
    fileprivate func upToDate() {
        Self.log.info("up to date")
        availableVersion = nil
        guard manualBrewCheck else { return }
        manualBrewCheck = false
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Fader \(Bundle.main.shortVersion) is the latest version."
        NSApp.activate()
        alert.runModal()
    }

    /// The check itself failed (feed unreachable, bad XML). A previously
    /// found version stays on the banner — a transient failure is not
    /// evidence the update disappeared.
    fileprivate func checkFailed(_ message: String) {
        Self.log.error("check failed: \(message, privacy: .public)")
        guard manualBrewCheck else { return }
        manualBrewCheck = false
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "The update feed is unreachable. Try again later."
        NSApp.activate()
        alert.runModal()
    }

    private func showBrewAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = "Fader \(version) is available"
        alert.informativeText = "This copy is managed by Homebrew — update from the terminal:\n\(Self.homebrewCommand)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Self.copyHomebrewCommand()
        }
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
    /// handled elsewhere — filter those, report the genuine failures.
    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain {
            let benign: [SUError] = [.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError]
            if benign.contains(where: { Int($0.rawValue) == nsError.code }) { return }
        }
        owner?.checkFailed(error.localizedDescription)
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
