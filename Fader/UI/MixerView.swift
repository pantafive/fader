import SwiftUI

/// The menu bar popover. Two tabs — output and microphone — switch the
/// volume slider, the device list, and the apps section; the disconnected
/// Bluetooth section is shared, a paired device is one thing regardless of
/// which way the audio flows.
struct MixerView: View {
    @Environment(MixerEngine.self) private var engine
    @Environment(UpdateController.self) private var updater

    @State private var direction: AudioDirection = .output
    /// Frame of the active-outputs zone in global coordinates — the drop
    /// target for pairing a second output device.
    @State private var pairZoneFrame: CGRect = .null
    @State private var isPairTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            directionPicker

            if direction == .output {
                ActiveOutputsSection(isPairTarget: isPairTarget)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        pairZoneFrame = frame
                    }
                if engine.isStarted, hasOutputListRows {
                    DeviceListSection(
                        monitor: engine.deviceMonitor,
                        excludedUIDs: activeOutputUIDs,
                        pairZone: pairZoneFrame,
                        onPairHover: { isPairTarget = $0 },
                        onPair: { engine.pair($0) }
                    )
                }
            } else {
                inputVolumeSection
                if engine.isStarted, engine.inputDeviceMonitor.devices.count > 1 {
                    DeviceListSection(monitor: engine.inputDeviceMonitor)
                }
            }

            if engine.isStarted, !disconnectedBluetooth.isEmpty {
                bluetoothSection
            }

            if engine.needsAudioCapturePermission {
                PermissionBanner()
            }

            Divider()

            if direction == .input {
                recordingAppsSection
            } else {
                appsSection
            }

            if let version = updater.availableVersion {
                Divider()
                UpdateBanner(version: version)
            }
        }
        .padding(12)
        .frame(width: 320)
        .task { engine.bluetooth.refresh() }
    }

    /// Active outputs live in the zone above the list, not in the list:
    /// multi-output members when pairing is on, otherwise the default device.
    private var activeOutputUIDs: Set<String> {
        if engine.multiOutput.isActive {
            return Set(engine.multiOutput.members.map(\.device.uid))
        }
        let monitor = engine.deviceMonitor
        return Set(monitor.devices.filter { $0.id == monitor.defaultDeviceID }.map(\.uid))
    }

    private var hasOutputListRows: Bool {
        engine.deviceMonitor.devices.contains { !activeOutputUIDs.contains($0.uid) }
    }

    /// Full-width segmented switch — the native compact picker is a fiddly
    /// click target for the popover's most-used control.
    private var directionPicker: some View {
        HStack(spacing: 2) {
            directionTab(.output, icon: "speaker.wave.2.fill", label: "Output")
            directionTab(.input, icon: "mic.fill", label: "Microphone")
        }
        .padding(2)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func directionTab(_ value: AudioDirection, icon: String, label: String) -> some View {
        Button {
            direction = value
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(direction == value ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    direction == value ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// "Disconnected" means absent from the HAL — that's what decides whether
    /// the device can play. IOBluetooth's own connection flag lags the HAL by
    /// seconds, which would leave a just-disconnected speaker in neither list.
    /// Presence is judged against the output list: every Bluetooth audio
    /// device has an output side, not all have a mic.
    private var disconnectedBluetooth: [BluetoothAudioDevice] {
        engine.bluetooth.paired.filter { peer in
            !engine.deviceMonitor.devices.contains { $0.matches(bluetoothID: peer.id) }
        }
    }

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: DeviceListSection.rowSpacing) {
            Text("Bluetooth")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
            ForEach(disconnectedBluetooth) { device in
                BluetoothRowView(device: device)
            }
        }
        .padding(.horizontal, -8)
    }

    private var inputVolumeSection: some View {
        let inputVolume = engine.inputVolume
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Input")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(inputVolume.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Input gain is absent or read-only on plenty of devices (gain
            // knob lives in hardware) — a live-looking slider that snaps back
            // reads as broken, so it dims and freezes instead.
            ControlSlider(
                value: Binding(
                    get: { inputVolume.volume },
                    set: { inputVolume.setVolume($0) }
                ),
                icon: inputVolume.isMuted ? "mic.slash.fill" : "mic.fill",
                iconDimmed: inputVolume.isMuted,
                onIconTap: inputVolume.canMute ? { inputVolume.toggleMute() } : nil
            )
            .disabled(!inputVolume.canSetVolume)
            .opacity(inputVolume.canSetVolume ? 1.0 : 0.4)
        }
    }

    /// Apps audible right now, plus silent ones the user has adjusted —
    /// hiding those would strand their saved volume.
    private var mixerApps: [AudioApp] {
        engine.processMonitor.apps.filter { $0.isPlaying || !engine.volume(for: $0).isNeutral }
    }

    @ViewBuilder
    private var appsSection: some View {
        if !engine.isStarted {
            waitingState
        } else if engine.multiOutput.isActive {
            // Per-app taps are suspended during multi-output (see
            // MixerEngine.createTap); live-looking sliders would be a lie.
            emptyState(icon: "slider.horizontal.3",
                       message: "Per-app volume is paused while playing to multiple outputs")
        } else if mixerApps.isEmpty {
            emptyState(icon: "waveform.slash", message: "Nothing is playing")
        } else {
            // MenuBarExtra windows size to the content's ideal height, and a
            // ScrollView's ideal height is zero — give it an explicit one.
            let apps = mixerApps
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(apps) { app in
                        AppRowView(app: app)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(CGFloat(apps.count), 6) * AppRowView.rowHeight)
        }
    }

    /// Core Audio has no per-app input gain — there is no input analog of the
    /// output process tap — so the mic tab lists who is capturing, no sliders.
    @ViewBuilder
    private var recordingAppsSection: some View {
        let apps = engine.processMonitor.apps.filter(\.isRecording)
        if !engine.isStarted {
            waitingState
        } else if apps.isEmpty {
            emptyState(icon: "mic.slash", message: "Nothing is using the microphone")
        } else {
            VStack(spacing: 2) {
                ForEach(apps) { app in
                    RecordingAppRow(app: app)
                }
            }
        }
    }

    private var waitingState: some View {
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
    }

    private func emptyState(icon: String, message: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }
}
