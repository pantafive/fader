import CoreAudio
import Testing

@Suite("BluetoothAudioProfile")
struct BluetoothAudioProfileTests {
    @Test("stereo high sample rate infers A2DP")
    func a2dpStereo() {
        let profile44 = BluetoothAudioProfile.infer(sampleRateHz: 44_100, outputChannels: 2)
        #expect(profile44 == .a2dp(sampleRateHz: 44_100))
        #expect(profile44?.isDegraded == false)
        #expect(profile44?.badgeText == "A2DP 44.1k")

        let profile48 = BluetoothAudioProfile.infer(sampleRateHz: 48_000, outputChannels: 2)
        #expect(profile48 == .a2dp(sampleRateHz: 48_000))
        #expect(profile48?.isDegraded == false)
        #expect(profile48?.badgeText == "A2DP 48k")
    }

    @Test("16 kHz mono infers degraded HFP mSBC")
    func hfpMSBC() {
        let profile = BluetoothAudioProfile.infer(sampleRateHz: 16_000, outputChannels: 1)
        #expect(profile == .hfpMSBC(sampleRateHz: 16_000))
        #expect(profile?.isDegraded == true)
        #expect(profile?.badgeText == "mSBC 16k")
    }

    @Test("8 kHz mono infers degraded HFP CVSD")
    func hfpCVSD() {
        let profile = BluetoothAudioProfile.infer(sampleRateHz: 8_000, outputChannels: 1)
        #expect(profile == .hfpCVSD(sampleRateHz: 8_000))
        #expect(profile?.isDegraded == true)
        #expect(profile?.badgeText == "CVSD 8k")
    }

    @Test("zero or invalid stream parameters return nil")
    func invalidInputs() {
        #expect(BluetoothAudioProfile.infer(sampleRateHz: 0, outputChannels: 2) == nil)
        #expect(BluetoothAudioProfile.infer(sampleRateHz: 44_100, outputChannels: 0) == nil)
    }

    @Test("AudioDevice only exposes bluetoothProfile for Bluetooth transports")
    func deviceTransportGate() {
        let bt = AudioDevice(
            id: 1, uid: "80-C3-BA-0F-35-A1:output", name: "MOMENTUM 4",
            transport: kAudioDeviceTransportTypeBluetooth,
            outputDataSource: 0, inputDataSource: 0,
            nominalSampleRate: 16_000, outputChannelCount: 1
        )
        #expect(bt.bluetoothProfile == .hfpMSBC(sampleRateHz: 16_000))

        let usb = AudioDevice(
            id: 2, uid: "usb-m4", name: "MOMENTUM 4",
            transport: kAudioDeviceTransportTypeUSB,
            outputDataSource: 0, inputDataSource: 0,
            nominalSampleRate: 48_000, outputChannelCount: 2
        )
        #expect(usb.bluetoothProfile == nil)
    }
}
