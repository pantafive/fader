import CoreAudio
import Darwin
import IOKit

/// Maps a device's identity signals to an SF Symbol. The cascade runs from
/// reliable to brittle — transport type, then jack data source / Bluetooth
/// minor class, then Apple-gear name matching — and a brittle signal only
/// refines a class, never downgrades it: renamed AirPods fall back to the
/// minor-class glyph, a device that reports nothing keeps its transport glyph.
enum DeviceSymbol {
    // MARK: - Wired

    /// Built-in jack data sources (IOAudioTypes.h port subtypes).
    private static let headphonesSource: UInt32 = 0x6864_706E // 'hdpn'
    private static let externalSpeakerSource: UInt32 = 0x6573_706B // 'espk'
    private static let externalMicSource: UInt32 = 0x656D_6963 // 'emic'
    private static let lineSource: UInt32 = 0x6C69_6E65 // 'line' (out and in)

    /// Symbol for a non-Bluetooth device. `dataSource` is the device's data
    /// source in the displayed direction, 0 when it exposes none. `mac` is
    /// injectable for tests only.
    static func wired(transport: UInt32,
                      dataSource: UInt32,
                      direction: AudioDirection,
                      mac: String = currentMac) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            builtIn(dataSource: dataSource, direction: direction, mac: mac)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            "display"
        case kAudioDeviceTransportTypeAirPlay:
            "airplay.audio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            "iphone"
        case kAudioDeviceTransportTypeVirtual:
            "waveform"
        case kAudioDeviceTransportTypeAggregate:
            // Someone else's multi-output (ours are filtered out): a stack
            // of devices, not one speaker.
            "hifispeaker.2"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeAVB:
            // A wired box of unknown nature: DAC, dock, interface. In the
            // input list it is at least certainly a microphone source.
            direction == .input ? "mic" : "cable.connector"
        default:
            direction == .input ? "mic" : "hifispeaker"
        }
    }

    private static func builtIn(dataSource: UInt32, direction: AudioDirection, mac: String) -> String {
        switch direction {
        case .output:
            switch dataSource {
            case headphonesSource: "headphones"
            case externalSpeakerSource, lineSource: "hifispeaker"
            // 'ispk' or no data source — the Mac's own speakers.
            default: mac
            }
        case .input:
            switch dataSource {
            case externalMicSource, lineSource: "mic"
            // 'imic' or no data source — the Mac's own microphone.
            default: mac
            }
        }
    }

    // MARK: - Bluetooth

    /// Minor device classes of the audio/video major (Bluetooth Assigned
    /// Numbers). Set by the manufacturer; plenty of gear reports 0.
    private enum BTMinor {
        static let microphone: UInt32 = 0x04
        static let loudspeaker: UInt32 = 0x05
        static let portableAudio: UInt32 = 0x07
        static let carAudio: UInt32 = 0x08
        static let hiFiAudio: UInt32 = 0x0A
    }

    static func bluetooth(name: String, minorClass: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods.gen3" }
        return switch minorClass {
        case BTMinor.loudspeaker, BTMinor.portableAudio, BTMinor.carAudio, BTMinor.hiFiAudio:
            "hifispeaker"
        case BTMinor.microphone:
            "mic"
        // Headset, hands-free, headphones — and uncategorized, where
        // headphones are by far the likeliest BT audio device.
        default:
            "headphones"
        }
    }

    // MARK: - This Mac

    /// Glyph for the machine's own speakers and microphone, like the System
    /// Settings Sound list.
    static let currentMac: String = mac(model: readModel() ?? "")

    /// Matches both marketing names ("Mac mini (M1, 2020)") and Intel model
    /// identifiers ("Macmini8,1"). Apple Silicon identifiers are opaque
    /// ("Mac16,10"), but those machines expose the marketing name instead.
    static func mac(model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("macbook") { return "laptopcomputer" }
        if lower.contains("imac") { return "desktopcomputer" }
        if lower.contains("mac mini") || lower.contains("macmini") { return "macmini" }
        if lower.contains("mac studio") || lower.contains("macstudio") { return "macstudio" }
        if lower.contains("mac pro") || lower.contains("macpro") { return "macpro.gen3" }
        return "laptopcomputer" // most Macs; also the pre-cascade default
    }

    /// Marketing name from the device tree (Apple Silicon), else the model
    /// identifier from sysctl (Intel).
    private static func readModel() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let data = IORegistryEntryCreateCFProperty(
                entry, "product-name" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Data,
                let name = String(bytes: data, encoding: .utf8) {
                return name.trimmingCharacters(in: .controlCharacters)
            }
        }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
