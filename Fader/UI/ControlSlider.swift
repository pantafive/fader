import SwiftUI

/// Control-Center-style volume slider: a capsule filled to the current value,
/// with a tappable leading icon (mute toggle) and drag-anywhere tracking.
struct ControlSlider: View {
    @Binding var value: Float
    var icon: String
    var iconDimmed: Bool = false
    var onIconTap: (() -> Void)?

    @State private var isDragging = false
    @State private var isHovering = false

    private let height: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary.opacity(0.5))

                Capsule()
                    .fill(.white.opacity(isDragging ? 1.0 : 0.9))
                    .frame(width: max(height, width * CGFloat(value)))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)

                Button {
                    onIconTap?()
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(iconDimmed ? 0.3 : 0.75))
                        .frame(width: height, height: height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
            .scaleEffect(isDragging ? 1.015 : 1.0)
            .animation(.spring(duration: 0.25), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        // The icon area handles taps; only treat it as a drag start
                        // when the pointer moves or lands beyond the icon.
                        if !isDragging, gesture.translation == .zero, gesture.location.x < height, onIconTap != nil {
                            return
                        }
                        isDragging = true
                        value = Float(min(max(gesture.location.x / width, 0), 1))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: height)
    }
}
