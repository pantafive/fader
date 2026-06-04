import SwiftUI

/// The menu bar popover: system output on top, per-app mixer below.
struct MixerView: View {
    @Environment(MixerEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            outputSection

            if engine.isStarted, engine.deviceMonitor.devices.count > 1 || !disconnectedBluetooth.isEmpty {
                devicesSection
            }

            if engine.needsAudioCapturePermission {
                PermissionBanner()
            }

            Divider()

            appsSection

            Divider()

            FooterView()
        }
        .padding(12)
        .frame(width: 320)
    }

    private var disconnectedBluetooth: [BluetoothAudioDevice] {
        engine.bluetooth.paired.filter { !$0.isConnected }
    }

    /// Bluetooth devices cluster together: wired and built-in outputs first,
    /// then connected Bluetooth, then paired-but-disconnected headphones.
    private var devicesSection: some View {
        let wired = engine.deviceMonitor.devices.filter { !$0.isBluetooth }
        let bluetooth = engine.deviceMonitor.devices.filter(\.isBluetooth)

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(wired) { device in
                DeviceRowView(device: device)
            }
            if !bluetooth.isEmpty || !disconnectedBluetooth.isEmpty {
                Text("Bluetooth")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                ForEach(bluetooth) { device in
                    DeviceRowView(device: device)
                }
                ForEach(disconnectedBluetooth) { device in
                    BluetoothRowView(device: device)
                }
            }
        }
        .padding(.horizontal, -8)
        .task { engine.bluetooth.refresh() }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Output")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(engine.systemVolume.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ControlSlider(
                value: Binding(
                    get: { engine.systemVolume.volume },
                    set: { engine.systemVolume.setVolume($0) }
                ),
                icon: engine.systemVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                iconDimmed: engine.systemVolume.isMuted,
                onIconTap: { engine.systemVolume.toggleMute() }
            )
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        if !engine.isStarted {
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the audio system…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 16)
        } else if engine.processMonitor.apps.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No apps using audio")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                Spacer()
            }
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(engine.processMonitor.apps) { app in
                        AppRowView(app: app)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 420)
        }
    }
}

/// Shown when tap creation failed — almost always missing the
/// System Audio Recording permission.
struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio access needed")
                    .font(.system(size: 11, weight: .semibold))
                Text("Allow Fader to record system audio in Privacy & Security.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") {
                let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                if let settingsURL = URL(string: url) {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
