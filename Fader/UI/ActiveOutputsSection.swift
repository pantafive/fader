import SwiftUI

/// The top zone of the output tab: every device playing right now, each with
/// its own volume slider. One device = the system default driven by the
/// system volume; two or more = multi-output members with per-device HAL
/// volume. Rows dragged from the device list below drop here to pair.
struct ActiveOutputsSection: View {
    @Environment(MixerEngine.self) private var engine
    /// True while a device-row drag hovers the zone.
    var isPairTarget: Bool

    private struct Row: Identifiable {
        let device: AudioDevice
        let volume: any VolumeControlling
        let removable: Bool
        var id: String { device.uid }
    }

    private var rows: [Row] {
        if engine.multiOutput.isActive {
            return engine.multiOutput.members.map { Row(device: $0.device, volume: $0.volume, removable: true) }
        }
        let monitor = engine.deviceMonitor
        guard let device = monitor.devices.first(where: { $0.id == monitor.defaultDeviceID }) else { return [] }
        return [Row(device: device, volume: engine.systemVolume, removable: false)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Output")
                .font(.system(size: 12, weight: .semibold))
            if rows.isEmpty {
                // The default is a device the list hides (someone else's
                // aggregate, mid-switch churn): name it, control it blind.
                fallbackRow
            } else {
                ForEach(rows) { row in
                    activeRow(row)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .overlay { if isPairTarget { dropHint } }
    }

    private func activeRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: row.device.symbolName(
                    direction: .output,
                    bluetoothPeer: engine.bluetoothPeer(for: row.device)
                ))
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                Text(row.device.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if row.removable {
                    Button {
                        engine.unpair(row.device)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop playing to this device")
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            slider(for: row.volume)
        }
    }

    /// Mirrors the input tab's rule: a dead slider dims instead of snapping
    /// back when the device exposes no settable volume.
    private func slider(for volume: any VolumeControlling) -> some View {
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

    private var fallbackRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(engine.systemVolume.deviceName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            slider(for: engine.systemVolume)
        }
    }

    /// Overlay, not a layout change: rows must not shift mid-drag or the
    /// drag math in the list below would feed on its own movement.
    private var dropHint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
            Text("Drop here to play together")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        }
    }
}
