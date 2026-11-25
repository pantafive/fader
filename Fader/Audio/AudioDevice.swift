import CoreAudio

/// An audio device with channels in the monitored direction.
struct AudioDevice: Identifiable, Hashable {
    /// Every aggregate Fader creates carries this name prefix, and
    /// AudioDeviceMonitor keys on it to keep our own plumbing out of the
    /// user-facing device list. Producers and the filter must share it.
    static let plumbingNamePrefix = "Fader"

    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    /// Per-scope data sources ('hdpn', 'ispk', 'imic', …), 0 when absent.
    /// Read at construction; on Apple Silicon plug/unplug swaps the HAL
    /// device itself, so the values can't go stale within one device's
    /// lifetime.
    let outputDataSource: UInt32
    let inputDataSource: UInt32
    /// Nominal sample rate (Hz) and output channel count reported by the HAL;
    /// used to distinguish Bluetooth A2DP stereo from HFP/SCO telephony mode.
    let nominalSampleRate: Double
    let outputChannelCount: Int

    init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        transport: UInt32,
        outputDataSource: UInt32,
        inputDataSource: UInt32,
        nominalSampleRate: Double = 0,
        outputChannelCount: Int = 0
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.outputDataSource = outputDataSource
        self.inputDataSource = inputDataSource
        self.nominalSampleRate = nominalSampleRate
        self.outputChannelCount = outputChannelCount
    }

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var bluetoothProfile: BluetoothAudioProfile? {
        guard isBluetooth else { return nil }
        return BluetoothAudioProfile.infer(sampleRateHz: nominalSampleRate, outputChannels: outputChannelCount)
    }

    /// One of Fader's own aggregates — a per-app tap wrapper or the
    /// multi-output. Plumbing, not a user choice.
    var isFaderPlumbing: Bool {
        transport == kAudioDeviceTransportTypeAggregate && name.hasPrefix(Self.plumbingNamePrefix)
    }

    /// CoreAudio UIDs for Bluetooth devices start with the MAC address,
    /// e.g. "50-C0-F0-00-1C-78:output" — IOBluetooth uses the same dashed form.
    func matches(bluetoothID: String) -> Bool {
        uid.lowercased().hasPrefix(bluetoothID.lowercased())
    }
}

extension AudioDevice {
    /// Reads the device's identity straight from the HAL; nil once it's gone.
    /// (Lives in an extension to keep the memberwise initializer.)
    init?(id: AudioObjectID) {
        guard let uid = try? id.readDeviceUID(),
              let name = try? id.readString(kAudioObjectPropertyName)
        else { return nil }
        var transport: UInt32 = 0
        try? id.read(kAudioDevicePropertyTransportType, into: &transport)
        var outputDataSource: UInt32 = 0
        try? id.read(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, into: &outputDataSource)
        var inputDataSource: UInt32 = 0
        try? id.read(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput, into: &inputDataSource)
        var nominalSampleRate: Float64 = 0
        try? id.read(kAudioDevicePropertyNominalSampleRate, into: &nominalSampleRate)
        let outputChannelCount = id.channelCount(scope: kAudioDevicePropertyScopeOutput)
        self.init(id: id, uid: uid, name: name, transport: transport,
                  outputDataSource: outputDataSource, inputDataSource: inputDataSource,
                  nominalSampleRate: nominalSampleRate, outputChannelCount: outputChannelCount)
    }
}
