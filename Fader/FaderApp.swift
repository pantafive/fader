import AppKit
import CoreAudio
import SwiftUI

/// Quit must dissolve an active multi-output: the public aggregate would
/// otherwise outlive the app and haunt Sound settings as the default.
/// Exception: relaunching into an update keeps the aggregate alive so the
/// next instance adopts it and audio never reroutes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var engine: MixerEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if RENDER_SHOTS
            // AppKit is fully up here — safe for ImageRenderer and icon lookups.
            if RenderHarness.isActive { RenderHarness.runAndExit() }
        #endif
        // As an LSUIElement agent with no open window, RunningBoard rates the
        // app's termination resistance at its lowest, so under disk pressure
        // the cache-delete daemon evicts it (exit reason 0xBADDD15C) and the
        // icon silently vanishes — it won't relaunch until next login. Raising
        // resistance tells the system not to reclaim us first; it's a strong
        // hint, not a guarantee under severe pressure.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar agent stays resident")
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isUpdateRelaunch = UpdateController.consumeRelaunchingForUpdate()
        // Process taps are private to this process and must always be faded and
        // released. Only the public multi-output aggregate survives an update
        // relaunch so the incoming instance can adopt it without rerouting.
        Self.engine?.fadeOutAndStop()
        if !isUpdateRelaunch {
            Self.engine?.multiOutput.shutdown()
        }
    }
}

@main
struct FaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine: MixerEngine
    @State private var updater: UpdateController
    @State private var statusMenu: StatusItemMenuController

    init() {
        #if RENDER_SHOTS
            // Render mode skips the menu bar, the single-instance guard, and the
            // HAL probe — applicationDidFinishLaunching shoots the screenshots and
            // exits before any of that would matter.
            if RenderHarness.isActive {
                let updater = UpdateController()
                _engine = State(initialValue: MixerEngine())
                _updater = State(initialValue: updater)
                _statusMenu = State(initialValue: StatusItemMenuController(updater: updater))
                return
            }
        #endif
        Self.yieldToRunningInstance()
        let engine = MixerEngine()
        let updater = UpdateController()
        let statusMenu = StatusItemMenuController(updater: updater)
        _engine = State(initialValue: engine)
        _updater = State(initialValue: updater)
        _statusMenu = State(initialValue: statusMenu)
        AppDelegate.engine = engine
        statusMenu.install()
        // The detached probe gates engine.start(): the first HAL contact
        // happens off the main thread, so a wedged coreaudiod hangs the probe
        // while the menu bar icon renders and shows a waiting state. start()
        // only runs once the HAL has proven responsive.
        Task.detached(priority: .userInitiated) {
            _ = try? AudioObjectID.readDefaultOutputDevice()
            await MainActor.run {
                engine.start()
            }
        }
    }

    /// A second copy (dev build, stray drag to another folder) must not run
    /// alongside the first: two engines would fight over process taps and
    /// the multi-output aggregate. Launch Services already refuses to
    /// double-launch the same bundle, so reaching this means a copy at a
    /// different path — name the live one and bow out.
    private static func yieldToRunningInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard let other = others.first else { return }
        let alert = NSAlert()
        alert.messageText = "Fader is already running"
        alert.informativeText = "Another copy is running from \(other.bundleURL?.path ?? "another location")."
        NSApp.activate()
        alert.runModal()
        exit(0)
    }

    /// Resolution-independent vector template icon drawn directly with
    /// AppKit so it stays razor-sharp at both 1x and 2x display scales.
    private static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let faders: [(x: CGFloat, knob: CGFloat)] = [
                (4, 0.30),
                (9, 0.72),
                (14, 0.48),
            ]
            let trackWidth: CGFloat = 1.6
            let trackTop: CGFloat = 16
            let trackBottom: CGFloat = 2
            let knobRadius: CGFloat = 2.4

            for fader in faders {
                let knobCenterY = trackBottom + (trackTop - trackBottom) * fader.knob

                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: fader.x - trackWidth / 2,
                        y: knobCenterY,
                        width: trackWidth,
                        height: trackTop - knobCenterY
                    ),
                    xRadius: trackWidth / 2,
                    yRadius: trackWidth / 2
                ).fill()

                NSColor.black.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: fader.x - trackWidth / 2,
                        y: trackBottom,
                        width: trackWidth,
                        height: knobCenterY - trackBottom
                    ),
                    xRadius: trackWidth / 2,
                    yRadius: trackWidth / 2
                ).fill()

                NSBezierPath(ovalIn: NSRect(
                    x: fader.x - knobRadius,
                    y: knobCenterY - knobRadius,
                    width: knobRadius * 2,
                    height: knobRadius * 2
                )).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environment(engine)
                .environment(updater)
        } label: {
            MenuBarLabel(engine: engine, appIcon: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
