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

    @ObservationIgnored private var endpoint: VolumeEndpoint
    @ObservationIgnored private var defaultDeviceListener: HALListener?
    @ObservationIgnored private var deviceListeners: [HALListener] = []

    init(direction: AudioDirection = .output) {
        self.direction = direction
        endpoint = VolumeEndpoint(deviceID: .unknown, scope: direction.scope)
    }

    #if RENDER_SHOTS
        /// Render harness only: publish slider state without a HAL device.
        func seedForRender(volume: Float, isMuted: Bool, deviceName: String,
                           canSetVolume: Bool = true, canMute: Bool = true) {
            self.volume = volume
            self.isMuted = isMuted
            self.deviceName = deviceName
            self.canSetVolume = canSetVolume
            self.canMute = canMute
        }
    #endif

    func start() {
        defaultDeviceListener = AudioObjectID.system.listen(direction.defaultDeviceSelector) {
            Task { @MainActor [weak self] in self?.attachToDefaultDevice() }
        }
        attachToDefaultDevice()
    }

    func setVolume(_ value: Float) {
        if let applied = endpoint.writeVolume(value) {
            volume = applied
        } else {
            readBack() // keep published state honest when the HAL write fails
        }
    }

    func toggleMute() {
        if let muted = endpoint.writeMute(!isMuted) {
            isMuted = muted
        } else {
            readBack()
        }
    }

    // MARK: - Private

    private func attachToDefaultDevice() {
        guard let next = try? AudioObjectID.readDefaultDevice(direction), next.isValid else { return }
        endpoint.deviceID = next
        deviceName = (try? next.readString(kAudioObjectPropertyName)) ?? ""
        canSetVolume = next.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       scope: direction.scope)
        canMute = next.isSettable(kAudioDevicePropertyMute, scope: direction.scope)

        deviceListeners = [
            next.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                        scope: direction.scope) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
            next.listen(kAudioDevicePropertyMute, scope: direction.scope) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
        ]
        readBack()
    }

    private func readBack() {
        if let value = endpoint.readVolume() {
            volume = value
        }
        if let muted = endpoint.readMute() {
            isMuted = muted
        }
    }
}
