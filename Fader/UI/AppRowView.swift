import SwiftUI

/// One mixer row: app icon, name, volume percentage, and a ControlSlider.
struct AppRowView: View {
    /// Vertical rhythm of the apps list (name line + slider + spacing);
    /// MixerView's scroll-frame height relies on it, like DeviceRowView's.
    static let rowHeight: CGFloat = 57

    @Environment(MixerEngine.self) private var engine
    let app: AudioApp

    var body: some View {
        let entry = engine.volume(for: app)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(entry.isMuted ? "muted" : "\(Int(entry.volume * 100))%")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            ControlSlider(
                value: Binding(
                    get: { entry.volume },
                    set: { engine.setVolume($0, for: app) }
                ),
                icon: sliderIcon(entry),
                iconDimmed: entry.isMuted,
                onIconTap: { engine.toggleMute(for: app) }
            )
            .opacity(entry.isMuted ? 0.55 : 1.0)
        }
        // Rows shown only for their saved volume (nothing audible right now)
        // dim, so live and idle apps read apart at a glance. Still fully
        // interactive — the knob that made an app quiet must stay reachable.
        .opacity(app.isPlaying ? 1.0 : 0.5)
        .animation(.easeOut(duration: 0.2), value: app.isPlaying)
        .contextMenu {
            Button("Reset to 100%") { engine.reset(app) }
        }
    }

    private func sliderIcon(_ entry: AppVolume) -> String {
        if entry.isMuted { return "speaker.slash.fill" }
        switch entry.volume {
        case 0: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// An app currently capturing the microphone. Indicator only: Core Audio
/// offers no per-app input gain to put a slider on.
struct RecordingAppRow: View {
    let app: AudioApp

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
        .frame(height: 28)
    }
}
