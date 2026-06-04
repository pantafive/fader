import SwiftUI

/// One mixer row: app icon, name, volume percentage, and a ControlSlider.
struct AppRowView: View {
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
