import AudioToolbox
import CoreAudio
import Foundation
import os

/// Owns the Core Audio plumbing that gives Fader control over one app's volume:
/// a process tap that mutes the app's native output, an aggregate device wrapping
/// the real output device, and an IO proc that re-renders the tapped audio with gain.
///
/// Threading: setup and teardown run on the main actor; `volume` and `isMuted` are
/// read lock-free by the real-time HAL IO thread. Aligned Float32/Bool loads and
/// stores are atomic on Apple silicon, so no locking is needed for these.
final class ProcessTap: @unchecked Sendable {
    static let logger = Logger(subsystem: "dev.pantafive.fader", category: "ProcessTap")
    /// Fader never needs exclusive hardware access, and its audio IO must not
    /// keep the CPU awake while the rest of the machine is idle.
    private static func configureHALPowerPolicy() {
        try? AudioObjectID.system.write(kAudioHardwarePropertySleepingIsAllowed, value: UInt32(1))
        try? AudioObjectID.system.write(kAudioHardwarePropertyHogModeIsAllowed, value: UInt32(0))
    }

    /// Slider position, 0.0...1.0. Read by the RT thread every buffer and
    /// run through `taperedGain` before it reaches the samples — the stored
    /// value stays linear position so the UI and VolumeStore keep their
    /// 0...1 semantics.
    private nonisolated(unsafe) var _volume: Float
    /// Mute flag. Read by the RT thread every buffer.
    private nonisolated(unsafe) var _isMuted: Bool
    /// Gain ramped towards `_volume` per frame to avoid clicks. RT thread only.
    private nonisolated(unsafe) var _currentGain: Float
    /// Per-frame ramp coefficient for ~30 ms exponential gain smoothing.
    /// Computed from the device sample rate in activate(); the render never
    /// runs before that, so the placeholder is inert.
    private nonisolated(unsafe) var _rampCoefficient: Float = 0
    /// The gain path assumes Float32 PCM. Verified at activation; on any other
    /// format the render falls back to bit-exact passthrough instead of
    /// reinterpreting foreign bytes as floats.
    private nonisolated(unsafe) var _isFloat32 = true

    var tapID = AudioObjectID.unknown
    var aggregateID = AudioObjectID.unknown
    var procID: AudioDeviceIOProcID?
    var tapDescription: CATapDescription?
    var idleTask: Task<Void, Never>?
    var isProcessPlaying = true
    private let ioQueue = DispatchQueue(label: "dev.pantafive.fader.io", qos: .userInitiated)

    let processObjectIDs: [AudioObjectID]
    @MainActor var isSuspended = false
    @MainActor var onOutputResumed: (@MainActor @Sendable () -> Void)?

    /// A resolved output device: the UID names the aggregate's sub-device, the
    /// object ID catches a device that died and re-published under the same
    /// UID — the aggregate stays bound to the corpse and the tapped app would
    /// otherwise sit muted with nobody re-rendering it.
    struct Output: Equatable {
        let uid: String
        let id: AudioObjectID
    }

    /// The output devices this tap's aggregate fans out to, clock first. The
    /// aggregate pins them at activation, so a route or default change is
    /// honoured by rebuilding the tap, not mutating it — this records the
    /// current pins.
    private(set) var activatedOutputs: [Output] = []

    var volume: Float {
        get { _volume }
        set { _volume = max(0, min(1, newValue)) }
    }

    var isMuted: Bool {
        get { _isMuted }
        set { _isMuted = newValue }
    }

    init(processObjectIDs: [AudioObjectID], volume: Float = 1.0, isMuted: Bool = false) {
        Self.configureHALPowerPolicy()
        self.processObjectIDs = processObjectIDs
        _volume = volume
        _isMuted = isMuted
        _currentGain = VolumeTaper.gain(position: volume)
    }

    /// Builds the tap → aggregate → IO proc chain. The first UID is the clock
    /// (and main) sub-device; any others stack on with drift compensation, so
    /// the app fans out to several devices at once.
    @MainActor
    func activate(outputs: [Output]) throws {
        guard !aggregateID.isValid else { return }
        guard let clockUID = outputs.first?.uid else { return }
        activatedOutputs = outputs

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "\(AudioDevice.plumbingNamePrefix) tap #\(processObjectIDs.first ?? 0)"

        var tap = AudioObjectID.unknown
        try checked(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        (tapID, tapDescription) = (tap, description)

        var aggregateDescription: [String: Any] = [
            // The plumbing prefix keeps it out of AudioDeviceMonitor's list.
            kAudioAggregateDeviceNameKey: "\(AudioDevice.plumbingNamePrefix) aggregate #\(processObjectIDs.first ?? 0)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputs.map {
                [kAudioSubDeviceUIDKey: $0.uid, kAudioSubDeviceDriftCompensationKey: $0.uid != clockUID]
            },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if outputs.count > 1 {
            aggregateDescription[kAudioAggregateDeviceIsStackedKey] = true
        }

        var aggregate = AudioObjectID.unknown
        try checked(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                    "create aggregate device")
        aggregateID = aggregate

        var sampleRate: Float64 = 48000
        try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, into: &sampleRate)
        _rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * 0.030))

        verifyStreamFormat()

        var proc: AudioDeviceIOProcID?
        try checked(
            // @Sendable strips inferred @MainActor isolation: the HAL invokes
            // this block on its real-time IO thread, and an isolated closure
            // would trap in dispatch_assert_queue. unowned(unsafe) avoids
            // per-buffer refcount traffic; it is safe because teardown destroys
            // the IO proc (blocking until the callback exits) before deinit.
            AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID,
                                               ioQueue) { @Sendable [unowned(unsafe) self] _, input, _, output, _ in
                render(input, into: output)
            },
            "create IO proc"
        )
        procID = proc
        try checked(AudioDeviceStart(aggregateID, procID), "start aggregate device")

        let processIDs = processObjectIDs.map(String.init).joined(separator: ",")
        Self.logger
            .info("Tap active for processes [\(processIDs, privacy: .public)]: tap \(tap), aggregate \(aggregate)")
    }

    /// Confirms the gain path's Float32 PCM assumption against the aggregate's
    /// actual stream format; any other format flips the render to passthrough.
    @MainActor
    private func verifyStreamFormat() {
        var format = AudioStreamBasicDescription()
        guard (try? aggregateID.read(kAudioDevicePropertyStreamFormat,
                                     scope: kAudioDevicePropertyScopeOutput,
                                     into: &format)) != nil else { return }
        _isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        if !_isFloat32 {
            Self.logger.warning("Aggregate stream is not Float32 PCM; gain disabled, passing through")
        }
    }

    /// Whether the private aggregate still exists HAL-side. Device churn can
    /// kill it under the tap; `.mutedWhenTapped` then leaves the app muted
    /// with nobody re-rendering it, so a dead aggregate means rebuild now.
    @MainActor
    var isAlive: Bool {
        guard aggregateID.isValid else { return false }
        var alive: UInt32 = 0
        guard (try? aggregateID.read(kAudioDevicePropertyDeviceIsAlive, into: &alive)) != nil else { return false }
        return alive != 0
    }

    /// Tears down in the HAL-required order: stop → IO proc → aggregate → tap.
    /// Releasing the tap restores the app's native output.
    @MainActor
    func invalidate() {
        stopIdleLifecycle()
        Self.destroy(aggregateID: aggregateID, tapID: tapID, procID: procID)
        procID = nil
        aggregateID = .unknown
        tapID = .unknown
        tapDescription = nil
    }

    deinit {
        idleTask?.cancel()
        // Safe off the main actor: no other reference exists by now, and the
        // HAL calls block until the IO proc has exited.
        Self.destroy(aggregateID: aggregateID, tapID: tapID, procID: procID)
    }

    private static func destroy(aggregateID: AudioObjectID, tapID: AudioObjectID, procID: AudioDeviceIOProcID?) {
        if aggregateID.isValid {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    // MARK: - Real-time path. No allocation, locks, ObjC, or logging below.

    private func render(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>) {
        if _isMuted {
            Self.silence(output)
            return
        }
        if !_isFloat32 {
            Self.passthrough(input, into: output)
            return
        }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let targetGain = VolumeTaper.gain(position: _volume)
        var gain = _currentGain
        let ramp = _rampCoefficient

        for (index, outBuffer) in outputs.enumerated() {
            guard let outData = outBuffer.mData else { continue }
            guard index < inputs.count, let inData = inputs[index].mData else {
                memset(outData, 0, Int(outBuffer.mDataByteSize))
                continue
            }
            // One ramp shared across the buffer list; in practice taps deliver
            // a single interleaved buffer, so this is exact.
            gain = TapMix.mix(
                input: inData.assumingMemoryBound(to: Float.self),
                inputLayout: TapMix.Layout(channels: Int(inputs[index].mNumberChannels),
                                           count: Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size),
                output: outData.assumingMemoryBound(to: Float.self),
                outputLayout: TapMix.Layout(channels: Int(outBuffer.mNumberChannels),
                                            count: Int(outBuffer.mDataByteSize) / MemoryLayout<Float>.size),
                gain: TapMix.Gain(current: gain, target: targetGain, ramp: ramp)
            )
        }
        _currentGain = gain
    }

    private static func silence(_ output: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    /// Bit-exact copy for unexpected stream formats: no gain, no reinterpretation.
    private static func passthrough(_ input: UnsafePointer<AudioBufferList>,
                                    into output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for (index, outBuffer) in UnsafeMutableAudioBufferListPointer(output).enumerated() {
            guard let outData = outBuffer.mData else { continue }
            let outBytes = Int(outBuffer.mDataByteSize)
            guard index < inputs.count, let inData = inputs[index].mData else {
                memset(outData, 0, outBytes)
                continue
            }
            let bytes = min(Int(inputs[index].mDataByteSize), outBytes)
            memcpy(outData, inData, bytes)
            if bytes < outBytes {
                memset(outData.advanced(by: bytes), 0, outBytes - bytes)
            }
        }
    }
}

/// Converts an OSStatus into a thrown HALError with context.
func checked(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else {
        throw HALError.operation(status, what())
    }
}
