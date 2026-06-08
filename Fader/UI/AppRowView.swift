import SwiftUI

/// Collects each app row's frame in global space so a device dragged out of
/// the list can be dropped onto a row to route that app's audio there. Keyed
/// by bundle identifier; last writer wins on the rare key collision.
struct AppRouteZonePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One mixer row: app icon, name, volume percentage, and a ControlSlider.
struct AppRowView: View {
    /// Vertical rhythm of a plain (unrouted) row — name line plus its slider;
    /// MixerView's scroll-frame height relies on it, like DeviceRowView's.
    static let rowHeight: CGFloat = 53
    /// A routed row instead sizes to its name line plus the device card: this
    /// header part, then one `routeDeviceHeight` per pinned device.
    static let routedHeaderHeight: CGFloat = 40
    static let routeDeviceHeight: CGFloat = 48

    @Environment(MixerEngine.self) private var engine
    let app: AudioApp
    /// True while a device is dragged over this row — highlights the drop.
    var isRouteTarget: Bool = false

    var body: some View {
        let entry = engine.volume(for: app)
        let routeUIDs = engine.routeUIDs(for: app)
        // A paused (silent, non-neutral) row dims so it reads apart from live
        // ones — but the pinned-device card stays bright: on a paused app its
        // outputs are exactly what the user wants to see.
        let pausedDim: Double = app.isPlaying ? 1.0 : 0.5

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                // A routed app's loudness lives on its per-device sliders, so
                // the app-level percentage gives way to them.
                if routeUIDs.isEmpty {
                    Text(entry.isMuted ? "muted" : "\(Int(entry.volume * 100))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .opacity(pausedDim)

            if routeUIDs.isEmpty {
                ControlSlider(
                    value: Binding(
                        get: { entry.volume },
                        set: { engine.setVolume($0, for: app) }
                    ),
                    icon: sliderIcon(entry),
                    iconDimmed: entry.isMuted,
                    onIconTap: { engine.toggleMute(for: app) }
                )
                .opacity((entry.isMuted ? 0.55 : 1.0) * pausedDim)
            } else {
                routeCard(routeUIDs)
            }
        }
        .padding(.horizontal, 6)
        .background(
            isRouteTarget ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AppRouteZonePreferenceKey.self,
                    value: [app.bundleID: proxy.frame(in: .global)]
                )
            }
        )
        .animation(.easeOut(duration: 0.2), value: app.isPlaying)
        .contextMenu {
            Button("Reset to 100%") { engine.reset(app) }
            if !engine.routeUIDs(for: app).isEmpty {
                Button("Play on default output") { engine.clearRoute(for: app) }
            }
        }
    }

    /// The pinned devices, each its own row with its own volume slider,
    /// grouped in an accent card that ties them to this app.
    private func routeCard(_ uids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(uids, id: \.self) { uid in
                routeDeviceRow(uid)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One pinned device: name with a tap-to-clear ✕, then its own volume
    /// slider. An absent device reads "Unavailable" and shows no slider — the
    /// pin is kept and re-applies once it returns.
    private func routeDeviceRow(_ uid: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(engine.routeDeviceName(forUID: uid) ?? "Unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    engine.unroute(app, from: uid)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Stop playing to this device")
            }
            .foregroundStyle(Color.accentColor)

            if let volume = engine.routeVolume(forUID: uid) {
                deviceSlider(volume)
            }
        }
    }

    /// A device's own volume slider — same control the multi-output members
    /// use; a device with no settable volume shows a dimmed, frozen slider.
    private func deviceSlider(_ volume: any VolumeControlling) -> some View {
        ControlSlider(
            value: Binding(
                get: { volume.volume },
                set: { volume.setVolume($0) }
            ),
            icon: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
            iconDimmed: volume.isMuted,
            onIconTap: volume.canMute ? { volume.toggleMute() } : nil
        )
        .disabled(!volume.canSetVolume)
        .opacity(volume.canSetVolume ? 1.0 : 0.4)
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
