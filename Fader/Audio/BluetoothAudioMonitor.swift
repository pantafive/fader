import Foundation
import IOBluetooth
import Observation
import os

/// A paired Bluetooth device with an audio profile.
struct BluetoothAudioDevice: Identifiable, Hashable {
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

    private(set) var paired: [BluetoothAudioDevice] = []
    /// Addresses with a connect/disconnect operation in flight.
    private(set) var busy: Set<String> = []

    /// Orders overlapping refreshes: a stale enumeration that finishes late
    /// must not overwrite a fresher list.
    @ObservationIgnored private var refreshGeneration = 0

    /// Enumerates off the main actor — IOBluetooth calls can block.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        Task.detached(priority: .userInitiated) {
            let devices = Self.readPairedAudioDevices()
            await MainActor.run { [weak self] in
                guard let self, generation == refreshGeneration else { return }
                paired = devices
            }
        }
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
        Task.detached(priority: .userInitiated) {
            let target = IOBluetoothDevice(addressString: address)
            let result = target?.openConnection() ?? kIOReturnError
            await MainActor.run { [weak self] in
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
    }

    func disconnect(_ device: BluetoothAudioDevice) {
        guard !busy.contains(device.id) else { return }
        busy.insert(device.id)
        let address = device.id
        Task.detached(priority: .userInitiated) {
            let target = IOBluetoothDevice(addressString: address)
            let result = target?.closeConnection() ?? kIOReturnError
            await MainActor.run { [weak self] in
                guard let self else { return }
                busy.remove(address)
                refresh()
                if result != kIOReturnSuccess {
                    Self.logger.error("Disconnect failed for \(device.name): IOReturn \(result)")
                }
            }
        }
    }
}
