import SwiftUI

/// The menu bar icon: Fader's mark by default; with the opt-in from the
/// status item menu, the glyph of the device playing right now — the same
/// symbol its row shows in the popover.
struct MenuBarLabel: View {
    static let showsOutputIconKey = "menuBarShowsOutputIcon"

    let engine: MixerEngine
    let appIcon: NSImage
    @AppStorage(Self.showsOutputIconKey) private var showsOutputIcon = false

    var body: some View {
        if showsOutputIcon, let symbol = outputSymbol {
            Image(systemName: symbol)
        } else {
            Image(nsImage: appIcon)
        }
    }

    /// Nil until the engine has a default it can name (startup, a default the
    /// list hides) — the app mark is the honest fallback there.
    private var outputSymbol: String? {
        if engine.multiOutput.isActive { return "hifispeaker.2" }
        let monitor = engine.deviceMonitor
        guard let device = monitor.devices.first(where: { $0.id == monitor.defaultDeviceID }) else { return nil }
        return device.symbolName(direction: .output, bluetoothPeer: engine.bluetoothPeer(for: device))
    }
}
