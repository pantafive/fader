import SwiftUI

/// One direction's device list: priority-ordered present devices (wired and
/// connected Bluetooth alike) — drag a row to set the order, which doubles as
/// the auto-switch priority. Stale devices collapse into the "Rarely used"
/// disclosure (also a drop target for demoting).
struct DeviceListSection: View {
    let monitor: AudioDeviceMonitor
    /// Devices shown in the active-outputs zone instead of this list.
    var excludedUIDs: Set<String> = []
    /// Frame of the active-outputs zone (global space); a drag ending inside
    /// it pairs the device instead of reordering. `.null` disables pairing.
    var pairZone: CGRect = .null
    var onPairHover: ((Bool) -> Void)?
    var onPair: ((AudioDevice) -> Void)?
    /// App rows (bundleID → global frame) a dragged device can drop onto to
    /// route that app's audio there. Empty disables routing.
    var appZones: [String: CGRect] = [:]
    var onRouteHover: ((String?) -> Void)?
    var onRoute: ((String, AudioDevice) -> Void)?

    /// Drag state: which row is in flight and how far it travelled.
    @State private var draggedUID: String?
    @State private var dragOffset: CGFloat = 0
    @State private var isOverPairZone = false
    @State private var isOverRouteZone = false

    static let rowSpacing: CGFloat = 2
    /// Distance between row centers — the unit of drag math.
    private static let rowPitch: CGFloat = DeviceRowView.rowHeight + rowSpacing

    var body: some View {
        let visible = monitor.devices.filter { !excludedUIDs.contains($0.uid) }
        let main = visible.filter { !monitor.isRarelyUsed($0) }
        let rarelyUsed = visible.filter { monitor.isRarelyUsed($0) }

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
            RarelyUsedDisclosure(
                devices: rarelyUsed,
                monitor: monitor,
                isDropTarget: isDemoteTargeted(main: main)
            )
        }
        .padding(.horizontal, -8)
    }

    /// Slot the dragged row currently aims at; `main.count` is the demote
    /// slot (the "Rarely used" row right below the list), allowed only for
    /// devices that can actually be demoted. While the cursor hovers the
    /// pair zone the row stays put — the drag is aiming elsewhere.
    private func dragTarget(from: Int, main: [AudioDevice]) -> Int {
        guard !isOverPairZone, !isOverRouteZone else { return from }
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
        case let .moved(translation, location):
            draggedUID = main[index].uid
            dragOffset = translation
            let over = onPair != nil && pairZone.contains(location)
            if over != isOverPairZone {
                isOverPairZone = over
                onPairHover?(over)
            }
            // Pairing wins over routing where the zones could ever overlap.
            let routeHit = over ? nil : appZones.first { $0.value.contains(location) }?.key
            if (routeHit != nil) != isOverRouteZone {
                isOverRouteZone = routeHit != nil
            }
            onRouteHover?(routeHit)
        case let .finished(location):
            defer {
                if isOverPairZone {
                    isOverPairZone = false
                    onPairHover?(false)
                }
                isOverRouteZone = false
                onRouteHover?(nil)
                draggedUID = nil
                dragOffset = 0
            }
            guard main.indices.contains(index) else { return }
            if let onPair, pairZone.contains(location) {
                onPair(main[index])
                return
            }
            if let onRoute, let bundleID = appZones.first(where: { $0.value.contains(location) })?.key {
                onRoute(bundleID, main[index])
                return
            }
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
