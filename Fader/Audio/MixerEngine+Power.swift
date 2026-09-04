import Foundation

extension MixerEngine {
    /// Transient connect/routing work is meaningless across sleep and can wake
    /// into stale object IDs. Stable taps stay alive until the wake resync can
    /// inspect them — eagerly dropping them would let apps resume at full volume.
    func prepareForSleep() {
        routingTask?.cancel()
        routingTask = nil
        bluetoothRefreshTask?.cancel()
        bluetoothRefreshTask = nil
        wakeResyncTask?.cancel()
        wakeResyncTask = nil
    }

    func recoverAfterWake() {
        wakeResyncTask?.cancel()
        resyncAudioState()
        // Drivers and IOBluetooth often publish their final object IDs shortly
        // after didWake. One controlled second pass replaces a notification
        // storm and catches devices that were not ready on the immediate pass.
        wakeResyncTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            wakeResyncTask = nil
            resyncAudioState()
        }
    }

    private func resyncAudioState() {
        deviceMonitor.refresh()
        inputDeviceMonitor.refresh()
        multiOutput.handleDevicesChanged(present: deviceMonitor.devices)
        systemVolume.resync()
        inputVolume.resync()
        processMonitor.refresh()
        bluetooth.refresh()
        reconcileTapRouting()
    }
}
