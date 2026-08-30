import Foundation
import IOBluetooth
import Observation
import os

/// A paired Bluetooth device with an audio profile.
struct BluetoothAudioDevice: Identifiable, Hashable, Sendable {
    /// MAC address in IOBluetooth form: "50-c0-f0-00-1c-78".
    let id: String
    let name: String
    let isConnected: Bool
    /// Minor class of the audio major (headphones vs. loudspeaker), 0 when
    /// the manufacturer didn't bother.
    let minorClass: UInt32

    var symbolName: String {
        DeviceSymbol.bluetooth(name: name, minorClass: minorClass)
    }
}

/// Lists paired Bluetooth audio devices and connects or disconnects them.
/// CoreAudio only sees a Bluetooth device once it is connected; this monitor
/// covers the paired-but-disconnected half of the picture.
@MainActor
@Observable
final class BluetoothAudioMonitor {
    private nonisolated static let logger = Logger(subsystem: "dev.pantafive.fader", category: "BluetoothAudioMonitor")
    /// IOBluetooth's legacy API is synchronous and can block for seconds. A
    /// dedicated serial queue keeps that work off Swift's cooperative executor
    /// and, critically, prevents refresh/connect/disconnect calls from piling
    /// into the Bluetooth daemon concurrently.
    private nonisolated static let ioQueue = DispatchQueue(label: "dev.pantafive.fader.bluetooth", qos: .utility)

    private(set) var paired: [BluetoothAudioDevice] = []
    /// Addresses with a connect/disconnect operation in flight.
    private(set) var busy: Set<String> = []

    /// At most one enumeration runs at a time. Notifications that arrive while
    /// it is in flight collapse into one follow-up read so the final snapshot is
    /// fresh without spawning an unbounded family of detached tasks.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false

    #if RENDER_SHOTS
        /// Render harness only: publish a paired list without touching IOBluetooth.
        func seedForRender(paired: [BluetoothAudioDevice]) {
            self.paired = paired
        }
    #endif

    /// Enumerates off the main actor — IOBluetooth calls can block.
    func refresh() {
        #if RENDER_SHOTS
            // Screenshots must not touch the live system; IOBluetooth/CoreBluetooth
            // access trips TCC and aborts the render process.
            if RenderHarness.isActive { return }
        #endif
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let devices = await Self.performIO(qos: .utility) {
                    Self.readPairedAudioDevices()
                }
                guard let self, !Task.isCancelled else { return }
                paired = devices
                if refreshPending {
                    refreshPending = false
                    continue
                }
                refreshTask = nil
                return
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private nonisolated static func readPairedAudioDevices() -> [BluetoothAudioDevice] {
        (IOBluetoothDevice.pairedDevices() ?? [])
            .compactMap { $0 as? IOBluetoothDevice }
            .compactMap { device in
                guard let address = device.addressString else { return nil }
                // Major device class 0x04 = audio (headphones, speakers, headsets).
                guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio else { return nil }
                Self.logger.debug("Paired \(device.name ?? address): minor class \(device.deviceClassMinor)")
                return BluetoothAudioDevice(
                    id: address,
                    name: device.name ?? address,
                    isConnected: device.isConnected(),
                    minorClass: UInt32(device.deviceClassMinor)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Opens the connection off the main thread; IOBluetooth blocks for seconds.
    func connect(_ device: BluetoothAudioDevice, onConnected: @escaping @MainActor (BluetoothAudioDevice) -> Void) {
        guard !busy.contains(device.id) else { return }
        busy.insert(device.id)
        let address = device.id
        Task { @MainActor [weak self] in
            let result = await Self.performIO(qos: .userInitiated) {
                let target = IOBluetoothDevice(addressString: address)
                return target?.openConnection() ?? kIOReturnError
            }
            guard let self else { return }
            busy.remove(address)
            refresh()
            if result == kIOReturnSuccess {
                onConnected(device)
            } else {
                Self.logger.error("Connect failed for \(device.name): IOReturn \(result)")
            }
        }
    }

    func disconnect(_ device: BluetoothAudioDevice) {
        guard !busy.contains(device.id) else { return }
        busy.insert(device.id)
        let address = device.id
        Task { @MainActor [weak self] in
            let result = await Self.performIO(qos: .userInitiated) {
                let target = IOBluetoothDevice(addressString: address)
                return target?.closeConnection() ?? kIOReturnError
            }
            guard let self else { return }
            busy.remove(address)
            refresh()
            if result != kIOReturnSuccess {
                Self.logger.error("Disconnect failed for \(device.name): IOReturn \(result)")
            }
        }
    }

    /// Bridges synchronous IOBluetooth calls onto the one serial legacy-API
    /// queue. The continuation carries only Sendable values back to Swift.
    private nonisolated static func performIO<T: Sendable>(
        qos: DispatchQoS,
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async(qos: qos) {
                continuation.resume(returning: operation())
            }
        }
    }
}
