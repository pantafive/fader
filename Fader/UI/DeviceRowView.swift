import SwiftUI

extension AudioDevice {
    /// SF Symbol for the row icon. The paired IOBluetooth peer, when one
    /// matches by MAC, carries the minor class and the canonical name.
    /// (Lives UI-side: Audio/ models stay free of presentation vocabulary.)
    func symbolName(direction: AudioDirection, bluetoothPeer: BluetoothAudioDevice?) -> String {
        if isBluetooth {
            return DeviceSymbol.bluetooth(
                name: bluetoothPeer?.name ?? name,
                minorClass: bluetoothPeer?.minorClass ?? 0
            )
        }
        return DeviceSymbol.wired(
            transport: transport,
            dataSource: direction == .output ? outputDataSource : inputDataSource,
            direction: direction
        )
    }
}

/// Circular SF Symbol badge matching macOS Control Center Sound/Bluetooth rows:
/// accent-filled when active, subtle translucent circle when inactive.
struct DeviceIconBadge: View {
    enum Style {
        case active
        case inactive
        case disconnected
    }

    let systemName: String
    let style: Style

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: 26, height: 26)
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(foregroundStyle)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .active: Color.accentColor
        case .inactive: Color.primary.opacity(0.08)
        case .disconnected: Color.primary.opacity(0.05)
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        switch style {
        case .active: AnyShapeStyle(.white)
        case .inactive: AnyShapeStyle(.primary)
        case .disconnected: AnyShapeStyle(.secondary)
        }
    }
}

/// One output device: transport icon, name, checkmark on the active one.
/// Clicking switches the system default output. Bluetooth devices get a
/// disconnect button on hover. With a `reorder` handler the whole row drags
/// to reorder — the native drag session never starts inside a MenuBarExtra
/// window, so this is a plain DragGesture; a 6pt threshold keeps clicks
/// distinct from grabs.
struct DeviceRowView: View {
    /// Vertical rhythm of the device list; MixerView's drag math relies on it.
    static let rowHeight: CGFloat = 34

    /// Translation drives the reorder math; the cursor location (global
    /// space, same as the pair zone's measured frame) decides drops into the
    /// active-outputs zone.
    enum ReorderEvent {
        case moved(translation: CGFloat, location: CGPoint)
        case finished(location: CGPoint)
    }

    @Environment(MixerEngine.self) private var engine
    let device: AudioDevice
    /// The monitor the row belongs to — output and input lists switch their
    /// own system default.
    let monitor: AudioDeviceMonitor
    var reorder: ((ReorderEvent) -> Void)?
    /// True while a *different* row is being dragged: rows sliding past the
    /// cursor must not flash their hover chrome.
    var suppressHover: Bool = false

    @State private var isHovering = false
    @State private var isDraggingRow = false

    private var isActive: Bool {
        monitor.defaultDeviceID == device.id
    }

    private var showsHover: Bool {
        (isHovering && !suppressHover) || isDraggingRow
    }

    private var bluetoothPeer: BluetoothAudioDevice? {
        engine.bluetoothPeer(for: device)
    }

    var body: some View {
        HStack(spacing: 10) {
            DeviceIconBadge(
                systemName: device.symbolName(direction: monitor.direction, bluetoothPeer: bluetoothPeer),
                style: isActive ? .active : .inactive
            )
            NativeLabel(text: device.name)
            Spacer()
            if let peer = bluetoothPeer, showsHover {
                Button {
                    engine.bluetooth.disconnect(peer)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Disconnect")
            } else if isActive {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background(
            showsHover ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { isHovering = $0 }
        .onTapGesture {
            monitor.setDefault(device)
        }
        .gesture(reorderGesture)
        // A reorderable row is grabbable — say so with the pointer, the only
        // hint the drag gestures (reorder, pair, route) get before they start.
        .pointerStyle(reorder != nil ? (isDraggingRow ? .grabActive : .grabIdle) : nil)
    }

    private var reorderGesture: some Gesture {
        // Global space: the row itself moves by the reported translation, so
        // measuring in its local space feeds the offset back into the gesture
        // and the row vibrates.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { gesture in
                guard reorder != nil else { return }
                isDraggingRow = true
                reorder?(.moved(translation: gesture.translation.height, location: gesture.location))
            }
            .onEnded { gesture in
                isDraggingRow = false
                reorder?(.finished(location: gesture.location))
            }
    }
}

/// Wired devices that haven't been the output lately, folded behind one row.
/// Expanding is per-popover-open state; selecting a device stamps it used and
/// promotes it to the main list. The row doubles as the drop target for
/// drag-demoting a device out of the main list; it stays visible even empty
/// so the demote affordance is discoverable, just dimmed with a (0).
struct RarelyUsedDisclosure: View {
    let devices: [AudioDevice]
    let monitor: AudioDeviceMonitor
    var isDropTarget: Bool = false

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        Button {
            if !devices.isEmpty { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text("Rarely used (\(devices.count))")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        isDropTarget
                            ? AnyShapeStyle(Color.accentColor)
                            : devices.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
                    )
                Spacer()
            }
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                isDropTarget
                    ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                    : isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .frame(height: DeviceRowView.rowHeight)
        .onHover { isHovering = $0 }
        .onChange(of: devices.isEmpty) { _, empty in
            if empty { isExpanded = false }
        }

        if isExpanded {
            ForEach(devices) { device in
                DeviceRowView(device: device, monitor: monitor)
            }
        }
    }
}

/// A paired Bluetooth audio device that is not connected: dimmed row,
/// clicking connects and routes audio to it.
struct BluetoothRowView: View {
    @Environment(MixerEngine.self) private var engine
    let device: BluetoothAudioDevice

    @State private var isHovering = false

    private var isBusy: Bool {
        engine.bluetooth.busy.contains(device.id)
    }

    /// Hover appearance, including the render harness's forced state — onHover
    /// never fires under ImageRenderer, so a screenshot couldn't show it otherwise.
    private var hovered: Bool {
        #if RENDER_SHOTS
            if RenderHarness.forcedHoverBluetoothID == device.id { return true }
        #endif
        return isHovering
    }

    var body: some View {
        Button {
            engine.connectBluetooth(device)
        } label: {
            HStack(spacing: 10) {
                DeviceIconBadge(systemName: device.symbolName, style: .disconnected)
                NativeLabel(text: device.name, color: .secondaryLabelColor)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else if hovered {
                    Text("Connect")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: DeviceRowView.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                hovered ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isBusy)
    }
}
