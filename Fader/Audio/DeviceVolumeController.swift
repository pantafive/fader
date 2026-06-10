import AudioToolbox
import CoreAudio
import Observation

/// What a volume slider binds to: the system default's volume
/// (SystemVolumeController) or one concrete device's (DeviceVolumeController).
@MainActor
protocol VolumeControlling: AnyObject, Observable {
    var volume: Float { get }
    var isMuted: Bool { get }
    var canSetVolume: Bool { get }
    var canMute: Bool { get }
    func setVolume(_ value: Float)
    func toggleMute()
}

extension SystemVolumeController: VolumeControlling {}

/// One device's VirtualMainVolume and mute in one scope — the HAL read/write
/// bodies shared by both VolumeControlling implementations, so a volume fix
/// can't land in one and miss the other. Lifecycle (listeners, capability
/// probes, device attachment) stays with the owners, where the two genuinely
/// differ.
@MainActor
struct VolumeEndpoint {
    var deviceID: AudioObjectID
    let scope: AudioObjectPropertyScope

    /// Clamps and writes; returns the value to publish, nil when the HAL
    /// write failed and the owner should re-read instead.
    func writeVolume(_ value: Float) -> Float? {
        let clamped = max(0, min(1, value))
        do {
            try deviceID.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, value: clamped)
            return clamped
        } catch {
            return nil
        }
    }

    /// Writes the mute flag; returns the state to publish, nil on failure.
    func writeMute(_ muted: Bool) -> Bool? {
        do {
            try deviceID.write(kAudioDevicePropertyMute, scope: scope, value: UInt32(muted ? 1 : 0))
            return muted
        } catch {
            return nil
        }
    }

    func readVolume() -> Float? {
        var value: Float32 = 1.0
        guard (try? deviceID.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  scope: scope,
                                  into: &value)) != nil else { return nil }
        return value
    }

    func readMute() -> Bool? {
        var muted: UInt32 = 0
        guard (try? deviceID.read(kAudioDevicePropertyMute, scope: scope, into: &muted)) != nil else { return nil }
        return muted != 0
    }
}

/// Volume and mute of one pinned output device. Multi-output members keep
/// their own HAL volume — the stacked aggregate exposes no master control,
/// so these per-device controllers are the only volume there is.
@MainActor
@Observable
final class DeviceVolumeController: VolumeControlling {
    var deviceID: AudioObjectID { endpoint.deviceID }

    private(set) var volume: Float = 1.0
    private(set) var isMuted = false
    private(set) var canSetVolume = true
    private(set) var canMute = true

    @ObservationIgnored private let endpoint: VolumeEndpoint
    @ObservationIgnored private var listeners: [HALListener] = []

    init(deviceID: AudioObjectID) {
        endpoint = VolumeEndpoint(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
        canSetVolume = deviceID.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                           scope: kAudioDevicePropertyScopeOutput)
        canMute = deviceID.isSettable(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        listeners = [
            deviceID.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                            scope: kAudioDevicePropertyScopeOutput) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
            deviceID.listen(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
        ]
        readBack()
    }

    #if RENDER_SHOTS
        /// Render harness only: a controller with published volume but no HAL
        /// device, listeners, or capability probe — the slider draws as live.
        init(renderVolume: Float, isMuted: Bool = false) {
            endpoint = VolumeEndpoint(deviceID: .unknown, scope: kAudioDevicePropertyScopeOutput)
            volume = renderVolume
            self.isMuted = isMuted
        }
    #endif

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

    private func readBack() {
        if let value = endpoint.readVolume() {
            volume = value
        }
        if let muted = endpoint.readMute() {
            isMuted = muted
        }
    }
}
