import SwiftUI

/// The menu bar popover. Two tabs — output and microphone — switch the
/// volume slider, the device list, and the apps section; the disconnected
/// Bluetooth section is shared, a paired device is one thing regardless of
/// which way the audio flows.
struct MixerView: View {
    @Environment(MixerEngine.self) private var engine

    @State private var direction: AudioDirection = .output

    private var activeMonitor: AudioDeviceMonitor {
        direction == .input ? engine.inputDeviceMonitor : engine.deviceMonitor
    }

    private var activeVolume: SystemVolumeController {
        direction == .input ? engine.inputVolume : engine.systemVolume
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            directionPicker

            volumeSection

            if engine.isStarted, activeMonitor.devices.count > 1 {
                DeviceListSection(monitor: activeMonitor)
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

            Divider()

            FooterView()
        }
        .padding(12)
        .frame(width: 320)
        .task { engine.bluetooth.refresh() }
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

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(direction == .input ? "Input" : "Output")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(activeVolume.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Input gain is absent or read-only on plenty of devices (gain
            // knob lives in hardware) — a live-looking slider that snaps back
            // reads as broken, so it dims and freezes instead.
            ControlSlider(
                value: Binding(
                    get: { activeVolume.volume },
                    set: { activeVolume.setVolume($0) }
                ),
                icon: volumeIcon,
                iconDimmed: activeVolume.isMuted,
                onIconTap: activeVolume.canMute ? { activeVolume.toggleMute() } : nil
            )
            .disabled(!activeVolume.canSetVolume)
            .opacity(activeVolume.canSetVolume ? 1.0 : 0.4)
        }
    }

    private var volumeIcon: String {
        if direction == .input {
            return activeVolume.isMuted ? "mic.slash.fill" : "mic.fill"
        }
        return activeVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill"
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
        } else if mixerApps.isEmpty {
            emptyState(icon: "waveform.slash", message: "Nothing is playing")
        } else {
            // MenuBarExtra windows size to the content's ideal height, and a
            // ScrollView's ideal height is zero — give it an explicit one.
            // rowHeight tracks AppRowView's layout: name line + slider + spacing.
            let rowHeight: CGFloat = 57
            let apps = mixerApps
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(apps) { app in
                        AppRowView(app: app)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(CGFloat(apps.count), 6) * rowHeight)
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

/// One direction's device list: priority-ordered present devices (wired and
/// connected Bluetooth alike) — drag a row to set the order, which doubles as
/// the auto-switch priority. Stale devices collapse into the "Rarely used"
/// disclosure (also a drop target for demoting).
struct DeviceListSection: View {
    let monitor: AudioDeviceMonitor

    /// Drag state: which row is in flight and how far it travelled.
    @State private var draggedUID: String?
    @State private var dragOffset: CGFloat = 0

    static let rowSpacing: CGFloat = 2
    /// Distance between row centers — the unit of drag math.
    private static let rowPitch: CGFloat = DeviceRowView.rowHeight + rowSpacing

    var body: some View {
        let main = monitor.devices.filter { !monitor.isRarelyUsed($0) }
        let rarelyUsed = monitor.devices.filter { monitor.isRarelyUsed($0) }

        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(main.enumerated()), id: \.element.id) { index, device in
                DeviceRowView(
                    device: device,
                    monitor: monitor,
                    reorder: { event in handleReorder(event, index: index, main: main) },
                    suppressHover: draggedUID != nil && draggedUID != device.uid
                )
                .offset(y: rowOffset(index: index, main: main))
                .zIndex(draggedUID == device.uid ? 1 : 0)
                .animation(
                    draggedUID == device.uid ? nil : .easeOut(duration: 0.15),
                    value: rowOffset(index: index, main: main)
                )
            }
            if !rarelyUsed.isEmpty || draggedUID != nil {
                RarelyUsedDisclosure(
                    devices: rarelyUsed,
                    monitor: monitor,
                    isDropTarget: isDemoteTargeted(main: main)
                )
            }
        }
        .padding(.horizontal, -8)
    }

    /// Slot the dragged row currently aims at; `main.count` is the demote
    /// slot (the "Rarely used" row right below the list), allowed only for
    /// devices that can actually be demoted.
    private func dragTarget(from: Int, main: [AudioDevice]) -> Int {
        let delta = Int((dragOffset / Self.rowPitch).rounded())
        let canDemote = !main[from].isBluetooth && monitor.defaultDeviceID != main[from].id
        return min(max(from + delta, 0), canDemote ? main.count : main.count - 1)
    }

    private func rowOffset(index: Int, main: [AudioDevice]) -> CGFloat {
        guard let dragged = draggedUID,
              let from = main.firstIndex(where: { $0.uid == dragged })
        else { return 0 }
        if index == from { return dragOffset }
        let target = dragTarget(from: from, main: main)
        if index > from, index <= target { return -Self.rowPitch }
        if index < from, index >= target { return Self.rowPitch }
        return 0
    }

    private func isDemoteTargeted(main: [AudioDevice]) -> Bool {
        guard let dragged = draggedUID,
              let from = main.firstIndex(where: { $0.uid == dragged })
        else { return false }
        return dragTarget(from: from, main: main) == main.count
    }

    private func handleReorder(_ event: DeviceRowView.ReorderEvent, index: Int, main: [AudioDevice]) {
        switch event {
        case let .moved(translation):
            draggedUID = main[index].uid
            dragOffset = translation
        case .finished:
            defer {
                draggedUID = nil
                dragOffset = 0
            }
            guard main.indices.contains(index) else { return }
            let target = dragTarget(from: index, main: main)
            if target == main.count {
                monitor.markRarelyUsed(main[index])
            } else if target != index {
                var order = main.map(\.uid)
                order.move(
                    fromOffsets: IndexSet(integer: index),
                    toOffset: target > index ? target + 1 : target
                )
                monitor.applyOrder(order)
            }
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
