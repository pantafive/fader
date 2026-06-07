import Testing

@Suite("DeviceSymbol")
struct DeviceSymbolTests {
    // Four-char codes mirrored from CoreAudio/IOAudioTypes; the production
    // constants are private by design.
    private let builtIn: UInt32 = 0x626C_746E // 'bltn'
    private let usb: UInt32 = 0x7573_6220 // 'usb '
    private let thunderbolt: UInt32 = 0x7468_756E // 'thun'
    private let hdmi: UInt32 = 0x6864_6D69 // 'hdmi'
    private let airPlay: UInt32 = 0x6169_7270 // 'airp'
    private let virtualTransport: UInt32 = 0x7669_7274 // 'virt'
    private let continuityWireless: UInt32 = 0x6363_776C // 'ccwl'
    private let aggregate: UInt32 = 0x6772_7570 // 'grup'
    private let headphonesSource: UInt32 = 0x6864_706E // 'hdpn'
    private let internalSpeaker: UInt32 = 0x6973_706B // 'ispk'
    private let externalSpeaker: UInt32 = 0x6573_706B // 'espk'
    private let internalMic: UInt32 = 0x696D_6963 // 'imic'
    private let externalMic: UInt32 = 0x656D_6963 // 'emic'

    @Test("built-in jack splits on data source")
    func builtInOutput() {
        #expect(DeviceSymbol.wired(
            transport: builtIn, dataSource: headphonesSource, direction: .output, mac: "macmini"
        ) == "headphones")
        #expect(DeviceSymbol.wired(
            transport: builtIn, dataSource: externalSpeaker, direction: .output, mac: "macmini"
        ) == "hifispeaker")
        // Internal speakers — and devices that report nothing — are the Mac.
        #expect(DeviceSymbol.wired(
            transport: builtIn, dataSource: internalSpeaker, direction: .output, mac: "macmini"
        ) == "macmini")
        #expect(DeviceSymbol.wired(
            transport: builtIn, dataSource: 0, direction: .output, mac: "macmini"
        ) == "macmini")
    }

    @Test("built-in input splits internal vs external mic")
    func builtInInput() {
        #expect(DeviceSymbol.wired(
            transport: builtIn, dataSource: internalMic, direction: .input, mac: "laptopcomputer"
        ) == "laptopcomputer")
        #expect(DeviceSymbol.wired(
            transport: builtIn, dataSource: externalMic, direction: .input, mac: "laptopcomputer"
        ) == "mic")
    }

    @Test("wired interfaces are direction-aware")
    func wiredInterfaces() {
        #expect(DeviceSymbol.wired(transport: usb, dataSource: 0, direction: .output) == "cable.connector")
        #expect(DeviceSymbol.wired(transport: usb, dataSource: 0, direction: .input) == "mic")
        #expect(DeviceSymbol.wired(transport: thunderbolt, dataSource: 0, direction: .output) == "cable.connector")
    }

    @Test("dedicated transports keep their glyphs")
    func dedicatedTransports() {
        #expect(DeviceSymbol.wired(transport: hdmi, dataSource: 0, direction: .output) == "display")
        #expect(DeviceSymbol.wired(transport: airPlay, dataSource: 0, direction: .output) == "airplay.audio")
        #expect(DeviceSymbol.wired(transport: virtualTransport, dataSource: 0, direction: .output) == "waveform")
        #expect(DeviceSymbol.wired(transport: continuityWireless, dataSource: 0, direction: .input) == "iphone")
        #expect(DeviceSymbol.wired(transport: aggregate, dataSource: 0, direction: .output) == "hifispeaker.2")
        // Unknown transport: something that plays vs. something that records.
        #expect(DeviceSymbol.wired(transport: 0, dataSource: 0, direction: .output) == "hifispeaker")
        #expect(DeviceSymbol.wired(transport: 0, dataSource: 0, direction: .input) == "mic")
    }

    @Test("AirPods match by name, most specific first")
    func airPodsByName() {
        #expect(DeviceSymbol.bluetooth(name: "Misha's AirPods Max", minorClass: 6) == "airpodsmax")
        #expect(DeviceSymbol.bluetooth(name: "Misha's AirPods Pro", minorClass: 6) == "airpodspro")
        #expect(DeviceSymbol.bluetooth(name: "Misha's AirPods", minorClass: 6) == "airpods.gen3")
    }

    @Test("renamed or third-party Bluetooth falls back to minor class")
    func bluetoothMinorClass() {
        #expect(DeviceSymbol.bluetooth(name: "WH-1000XM4", minorClass: 6) == "headphones")
        #expect(DeviceSymbol.bluetooth(name: "JBL Flip 6", minorClass: 5) == "hifispeaker")
        #expect(DeviceSymbol.bluetooth(name: "Beats Pill", minorClass: 5) == "hifispeaker")
        #expect(DeviceSymbol.bluetooth(name: "BT Mic", minorClass: 4) == "mic")
        // Uncategorized — headphones are the likeliest BT audio device.
        #expect(DeviceSymbol.bluetooth(name: "Mystery Buds", minorClass: 0) == "headphones")
    }

    @Test("Mac glyph matches marketing names and Intel identifiers")
    func macModels() {
        #expect(DeviceSymbol.mac(model: "Mac mini (M1, 2020)") == "macmini")
        #expect(DeviceSymbol.mac(model: "Macmini8,1") == "macmini")
        #expect(DeviceSymbol.mac(model: "MacBook Pro (14-inch, Nov 2023)") == "laptopcomputer")
        #expect(DeviceSymbol.mac(model: "MacBookAir9,1") == "laptopcomputer")
        #expect(DeviceSymbol.mac(model: "Mac Studio (2022)") == "macstudio")
        #expect(DeviceSymbol.mac(model: "iMac20,1") == "desktopcomputer")
        // iMac Pro is an iMac before it is a Pro.
        #expect(DeviceSymbol.mac(model: "iMacPro1,1") == "desktopcomputer")
        #expect(DeviceSymbol.mac(model: "MacPro7,1") == "macpro.gen3")
        #expect(DeviceSymbol.mac(model: "") == "laptopcomputer")
    }
}
