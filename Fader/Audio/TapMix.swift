import Foundation

/// The pure math of ProcessTap's render: ramped gain plus channel-layout
/// adaptation, split from the tap so it is unit-testable without a HAL.
/// Called from the real-time IO callback — no allocation, no locks.
enum TapMix {
    /// One interleaved buffer's shape: channel count and total sample count.
    struct Layout {
        let channels: Int
        let count: Int
    }

    /// The gain ramp state: where it is, where it heads, how fast per frame.
    struct Gain {
        let current: Float
        let target: Float
        let ramp: Float
    }

    /// Applies the ramped gain while adapting the tap's channel layout to the
    /// output stream's. The tap always delivers a stereo mixdown, but the
    /// output can be mono (a Bluetooth headset dropping to HFP mid-call) or
    /// wider; index-matched copying would smear interleaved frames across
    /// time. Equal layouts copy 1:1, a narrower output averages each frame's
    /// channels, a wider one repeats the last input channel. Returns the gain
    /// after the final frame.
    static func mix(input: UnsafePointer<Float>, inputLayout: Layout,
                    output: UnsafeMutablePointer<Float>, outputLayout: Layout,
                    gain: Gain) -> Float {
        let inChannels = max(1, inputLayout.channels)
        let outChannels = max(1, outputLayout.channels)
        let frames = min(inputLayout.count / inChannels, outputLayout.count / outChannels)
        let targetGain = gain.target
        let ramp = gain.ramp
        var frameGain = gain.current

        for frame in 0 ..< frames {
            frameGain += (targetGain - frameGain) * ramp
            let inBase = frame * inChannels
            let outBase = frame * outChannels
            if inChannels == outChannels {
                for channel in 0 ..< outChannels {
                    output[outBase + channel] = input[inBase + channel] * frameGain
                }
            } else if outChannels == 1 {
                var sum: Float = 0
                for channel in 0 ..< inChannels {
                    sum += input[inBase + channel]
                }
                output[outBase] = sum / Float(inChannels) * frameGain
            } else {
                for channel in 0 ..< outChannels {
                    output[outBase + channel] = input[inBase + min(channel, inChannels - 1)] * frameGain
                }
            }
        }
        // Snap once converged: stops the asymptotic tail (denormal-prone
        // when ramping to 0 on non-Apple-silicon FPUs).
        if abs(frameGain - targetGain) < 1e-6 {
            frameGain = targetGain
        }
        let written = frames * outChannels
        if written < outputLayout.count {
            output.advanced(by: written).update(repeating: 0, count: outputLayout.count - written)
        }
        return frameGain
    }
}
