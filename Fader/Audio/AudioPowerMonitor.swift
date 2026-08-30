import AppKit

/// Bridges workspace power notifications onto the main actor. The monitor is
/// intentionally app-lifetime: NotificationCenter retains opaque observer
/// tokens, while their callbacks only retain this object weakly.
@MainActor
final class AudioPowerMonitor {
    private let onSleep: @MainActor @Sendable () -> Void
    private let onWake: @MainActor @Sendable () -> Void
    private var observers: [NSObjectProtocol] = []

    init(onSleep: @escaping @MainActor @Sendable () -> Void,
         onWake: @escaping @MainActor @Sendable () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: NSWorkspace.shared, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: NSWorkspace.shared, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onWake() }
            },
        ]
    }
}
