import AppKit
import SwiftUI

/// Native macOS volume slider paired with a leading mute toggle button.
/// Keeps hover scroll-wheel adjustment so trackpad/mouse scrolling adjusts
/// volume directly without scrolling the surrounding list.
struct ControlSlider: View {
    @Binding var value: Float
    var icon: String
    var iconDimmed: Bool = false
    var onIconTap: (() -> Void)?

    @State private var scrollMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onIconTap?()
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(iconDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary.opacity(0.75)))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onIconTap == nil)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: 0 ... 1
            )
        }
        .onHover { hovering in
            if hovering, scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    adjust(by: event)
                    return nil // consumed: don't also scroll the app list
                }
            } else if !hovering {
                removeScrollMonitor()
            }
        }
        .onDisappear(perform: removeScrollMonitor)
    }

    /// Trackpads send many precise pixel deltas per gesture, wheel mice send
    /// coarse line deltas — scale each so a comfortable gesture sweeps
    /// roughly half the slider.
    private func adjust(by event: NSEvent) {
        let scale: Float = event.hasPreciseScrollingDeltas ? 1 / 120 : 1 / 12
        value = min(max(value + Float(event.scrollingDeltaY) * scale, 0), 1)
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
