import Foundation

/// Inferred Bluetooth audio profile from CoreAudio's live stream parameters.
/// CoreAudio does not expose A2DP's compressed codec (AAC vs. SBC), but
/// A2DP vs. HFP/SCO splits cleanly on channel count and nominal sample rate:
///   - HFP/SCO (mSBC): 1 channel, ~16 kHz
///   - HFP/SCO (CVSD): 1 channel, ~8 kHz
///   - A2DP (stereo):  ≥2 channels, >24 kHz (typically 44.1 or 48 kHz)
enum BluetoothAudioProfile: Equatable, Hashable, Sendable {
    case a2dp(sampleRateHz: Double)
    case hfpMSBC(sampleRateHz: Double)
    case hfpCVSD(sampleRateHz: Double)
    case hfpOther(sampleRateHz: Double)

    static func infer(sampleRateHz: Double, outputChannels: Int) -> Self? {
        guard sampleRateHz > 0, outputChannels > 0 else { return nil }
        if outputChannels == 1 || sampleRateHz <= 24_000 {
            if sampleRateHz >= 12_000 {
                return .hfpMSBC(sampleRateHz: sampleRateHz)
            }
            if sampleRateHz >= 6_000 {
                return .hfpCVSD(sampleRateHz: sampleRateHz)
            }
            return .hfpOther(sampleRateHz: sampleRateHz)
        }
        return .a2dp(sampleRateHz: sampleRateHz)
    }

    var sampleRateHz: Double {
        switch self {
        case let .a2dp(hz), let .hfpMSBC(hz), let .hfpCVSD(hz), let .hfpOther(hz):
            hz
        }
    }

    /// True when the headset has dropped into low-bandwidth hands-free
    /// telephony mode (mono 8/16 kHz) instead of stereo A2DP.
    var isDegraded: Bool {
        switch self {
        case .a2dp: false
        case .hfpMSBC, .hfpCVSD, .hfpOther: true
        }
    }

    /// Compact pill label for device rows (e.g. "A2DP 44.1k", "mSBC 16k").
    var badgeText: String {
        let rate = Self.shortSampleRate(sampleRateHz)
        switch self {
        case .a2dp: return "A2DP \(rate)"
        case .hfpMSBC: return "mSBC \(rate)"
        case .hfpCVSD: return "CVSD \(rate)"
        case .hfpOther: return "HFP \(rate)"
        }
    }

    /// Detailed tooltip explaining the active Bluetooth profile.
    var helpText: String {
        let rate = Self.fullSampleRate(sampleRateHz)
        switch self {
        case .a2dp:
            return "Bluetooth A2DP stereo (\(rate))"
        case .hfpMSBC:
            return "Bluetooth Hands-Free mSBC (\(rate) mono) — switch Input off this headset for stereo A2DP"
        case .hfpCVSD:
            return "Bluetooth Hands-Free CVSD (\(rate) mono) — switch Input off this headset for stereo A2DP"
        case .hfpOther:
            return "Bluetooth Hands-Free (\(rate) mono) — switch Input off this headset for stereo A2DP"
        }
    }

    static func shortSampleRate(_ hz: Double) -> String {
        let khz = hz / 1000.0
        if abs(khz - khz.rounded()) < 0.05 {
            return "\(Int(khz.rounded()))k"
        }
        return String(format: "%.1fk", khz)
    }

    static func fullSampleRate(_ hz: Double) -> String {
        let khz = hz / 1000.0
        if abs(khz - khz.rounded()) < 0.05 {
            return "\(Int(khz.rounded())) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}
