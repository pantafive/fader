import AudioToolbox
import CoreAudio
import Observation
import os

/// Reads and writes the default device's main volume and mute for one
/// direction, staying in sync with changes made elsewhere (volume keys,
/// Control Center). Input gain is absent or read-only on plenty of devices
/// (pro interfaces put it on a hardware knob) — `canSetVolume`/`canMute`
/// tell the UI when to disable the controls.
@MainActor
@Observable
final class SystemVolumeController {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "SystemVolume")

    let direction: AudioDirection

    private(set) var volume: Float = 1.0
    private(set) var isMuted = false
    private(set) var deviceName = ""
    private(set) var canSetVolume = true
    private(set) var canMute = true

    @ObservationIgnored private var device = AudioObjectID.unknown
    @ObservationIgnored private var defaultDeviceListener: HALListener?
    @ObservationIgnored private var deviceListeners: [HALListener] = []

    init(direction: AudioDirection = .output) {
        self.direction = direction
    }

    func start() {
        defaultDeviceListener = AudioObjectID.system.listen(direction.defaultDeviceSelector) {
            Task { @MainActor [weak self] in self?.attachToDefaultDevice() }
        }
        attachToDefaultDevice()
    }

    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        do {
            try device.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                             scope: direction.scope,
                             value: clamped)
            volume = clamped
        } catch {
            readBack() // keep published state honest when the HAL write fails
        }
    }

    func toggleMute() {
        let next: UInt32 = isMuted ? 0 : 1
        do {
            try device.write(kAudioDevicePropertyMute, scope: direction.scope, value: next)
            isMuted = next != 0
        } catch {
            readBack()
        }
    }

    // MARK: - Private

    private func attachToDefaultDevice() {
        guard let next = try? AudioObjectID.readDefaultDevice(direction), next.isValid else { return }
        device = next
        deviceName = (try? device.readString(kAudioObjectPropertyName)) ?? ""
        canSetVolume = device.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                         scope: direction.scope)
        canMute = device.isSettable(kAudioDevicePropertyMute, scope: direction.scope)

        deviceListeners = [
            device.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                          scope: direction.scope) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
            device.listen(kAudioDevicePropertyMute, scope: direction.scope) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
        ]
        readBack()
    }

    private func readBack() {
        var value: Float32 = 1.0
        if (try? device.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                             scope: direction.scope,
                             into: &value)) != nil {
            volume = value
        }
        var muted: UInt32 = 0
        if (try? device.read(kAudioDevicePropertyMute, scope: direction.scope, into: &muted)) != nil {
            isMuted = muted != 0
        }
    }
}
