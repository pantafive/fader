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

/// One output device: transport icon, name, checkmark on the active one.
/// Clicking switches the system default output. Bluetooth devices get a
/// disconnect button on hover. With a `reorder` handler the whole row drags
/// to reorder — the native drag session never starts inside a MenuBarExtra
/// window, so this is a plain DragGesture; a 6pt threshold keeps clicks
/// distinct from grabs.
struct DeviceRowView: View {
    /// Vertical rhythm of the device list; MixerView's drag math relies on it.
    static let rowHeight: CGFloat = 28

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
        HStack(spacing: 8) {
            Image(systemName: device.symbolName(direction: monitor.direction, bluetoothPeer: bluetoothPeer))
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(device.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            if let peer = bluetoothPeer, showsHover {
                Button {
                    engine.bluetooth.disconnect(peer)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Disconnect")
            } else if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .background(
            showsHover ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovering = $0 }
        .onTapGesture {
            monitor.setDefault(device)
        }
        .gesture(reorderGesture)
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

    var body: some View {
        Button {
            engine.connectBluetooth(device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text(device.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else if isHovering {
                    Text("Connect")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isBusy)
    }
}
