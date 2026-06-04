import SwiftUI

/// Control-Center-style volume slider: a capsule track filled to the current
/// value, a circular thumb riding the fill edge (HIG: macOS linear sliders
/// have a visible thumb), and a tappable leading icon for mute.
struct ControlSlider: View {
    @Binding var value: Float
    var icon: String
    var iconDimmed: Bool = false
    var onIconTap: (() -> Void)?

    @State private var isDragging = false
    @State private var scrollMonitor: Any?

    private let height: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // The thumb center stays inside the capsule; fill always reaches it.
            let thumbCenter = height / 2 + (width - height) * CGFloat(value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }

                Capsule()
                    .fill(.white)
                    .frame(width: thumbCenter + height / 2)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(.white)
                            .frame(width: height, height: height)
                            .shadow(color: .black.opacity(0.25), radius: isDragging ? 4 : 2, y: 1)
                    }

                Button {
                    onIconTap?()
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(iconDimmed ? 0.25 : 0.6))
                        .frame(width: height, height: height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .compositingGroup()
            .animation(.easeOut(duration: 0.08), value: isDragging)
            // Smooths scroll-wheel steps; direct finger drags stay 1:1.
            .animation(isDragging ? nil : .easeOut(duration: 0.12), value: value)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        // A motionless touch on the icon is a mute tap, not a drag.
                        if !isDragging, gesture.translation == .zero, gesture.location.x < height, onIconTap != nil {
                            return
                        }
                        isDragging = true
                        let usable = max(width - height, 1)
                        value = Float(min(max((gesture.location.x - height / 2) / usable, 0), 1))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: height)
        // Scroll over the slider adjusts the value. The monitor lives only
        // while the cursor is over this slider, so it sees exactly the events
        // meant for it; installing on hover (not appear) keeps one popover
        // open/close cycle from stacking monitors.
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
