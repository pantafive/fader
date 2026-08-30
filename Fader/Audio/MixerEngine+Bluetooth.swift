import Foundation

extension MixerEngine {
    /// Paired IOBluetooth peer of a HAL device, when one matches by MAC.
    func bluetoothPeer(for device: AudioDevice) -> BluetoothAudioDevice? {
        bluetooth.paired.first { device.matches(bluetoothID: $0.id) }
    }

    /// Connects Bluetooth headphones and routes output to them once CoreAudio
    /// picks the device up.
    func connectBluetooth(_ device: BluetoothAudioDevice) {
        bluetooth.connect(device) { [weak self] connected in
            self?.routeWhenAvailable(connected)
        }
    }

    /// The HAL device for a Bluetooth peer appears a moment after the link
    /// opens; its UID starts with the MAC address. Poll briefly, then route.
    /// A new connect cancels the previous poll so rapid reconnects don't race.
    private func routeWhenAvailable(_ device: BluetoothAudioDevice) {
        routingTask?.cancel()
        routingTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 16 {
                guard let self, !Task.isCancelled else { return }
                if let halDevice = deviceMonitor.devices.first(where: { $0.matches(bluetoothID: device.id) }) {
                    deviceMonitor.setDefault(halDevice)
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            // HAL notifications normally populated the monitor. One explicit
            // read at the deadline covers a lost callback without hammering the
            // main actor with sixteen full device enumerations.
            guard let self, !Task.isCancelled else { return }
            deviceMonitor.refresh()
            if let halDevice = deviceMonitor.devices.first(where: { $0.matches(bluetoothID: device.id) }) {
                deviceMonitor.setDefault(halDevice)
            }
        }
    }

    /// Twice: once now, once after IOBluetooth's connection state has had a
    /// moment to settle — it lags the HAL by a beat in both directions.
    func refreshBluetoothSoon() {
        bluetooth.refresh()
        bluetoothRefreshTask?.cancel()
        bluetoothRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.bluetooth.refresh()
        }
    }
}
