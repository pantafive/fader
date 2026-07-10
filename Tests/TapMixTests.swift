import Testing

/// Runs TapMix.mix over value arrays; converged gain (gain == target) unless
/// a test exercises the ramp itself.
private func mixed(input: [Float], inputChannels: Int,
                   outputChannels: Int, outputCount: Int,
                   gain: Float = 1, targetGain: Float = 1, ramp: Float = 1) -> (output: [Float], gain: Float) {
    var output = [Float](repeating: .nan, count: outputCount)
    var finalGain: Float = 0
    input.withUnsafeBufferPointer { inPtr in
        output.withUnsafeMutableBufferPointer { outPtr in
            finalGain = TapMix.mix(
                input: inPtr.baseAddress!,
                inputLayout: TapMix.Layout(channels: inputChannels, count: input.count),
                output: outPtr.baseAddress!,
                outputLayout: TapMix.Layout(channels: outputChannels, count: outputCount),
                gain: TapMix.Gain(current: gain, target: targetGain, ramp: ramp)
            )
        }
    }
    return (output, finalGain)
}

// BUG: tapped apps sounded garbled ("robotic voice") on mono outputs.
//
// Reported: owner, 2026-07-10 — voice in Telegram calls turned robotic while
//   the app had a Fader volume set and a Bluetooth headset was in call mode.
// Date: 2026-07-10
//
// What happened:
//   A Bluetooth headset drops to the mono HFP profile during calls. The tap
//   always delivers an interleaved stereo mixdown, and the render copied it
//   sample-for-sample into the mono output stream — L,R pairs became
//   consecutive mono frames, playing the audio garbled at half speed.
//
// Root cause:
//   The render indexed input and output buffers identically, assuming their
//   channel layouts matched; nothing re-checked the layout after activation.
//
// Fix:
//   TapMix.mix (extracted from ProcessTap.render) adapts layouts per frame:
//   narrower outputs average each frame's channels, wider ones repeat the
//   last channel.
@Suite("bugfixes: TapMix channel adaptation")
struct BugTapMixChannelTests {
    @Test("bug: stereo tap into a mono (HFP) output downmixes per frame")
    func bugStereoToMonoDownmix() {
        let stereo: [Float] = [0.25, 0.75, -1.0, 1.0, 0.5, 0.5]

        let result = mixed(input: stereo, inputChannels: 2, outputChannels: 1, outputCount: 3)

        #expect(result.output == [0.5, 0.0, 0.5])
    }

    @Test("matching layouts copy 1:1 with gain applied")
    func matchingLayouts() {
        let stereo: [Float] = [0.25, 0.5, -1.0, 1.0]

        let result = mixed(input: stereo, inputChannels: 2, outputChannels: 2, outputCount: 4,
                           gain: 0.5, targetGain: 0.5)

        #expect(result.output == [0.125, 0.25, -0.5, 0.5])
        #expect(result.gain == 0.5)
    }

    @Test("mono tap into a stereo output repeats the channel")
    func monoToStereo() {
        let result = mixed(input: [0.25, -0.5], inputChannels: 1, outputChannels: 2, outputCount: 4)

        #expect(result.output == [0.25, 0.25, -0.5, -0.5])
    }

    @Test("output frames the input can't fill are zeroed, not left stale")
    func zeroFillsTail() {
        let result = mixed(input: [0.5, 0.5], inputChannels: 2, outputChannels: 2, outputCount: 6)

        #expect(result.output == [0.5, 0.5, 0, 0, 0, 0])
    }

    @Test("gain ramps monotonically toward the target across frames")
    func rampProgresses() {
        let input = [Float](repeating: 1, count: 8)

        let result = mixed(input: input, inputChannels: 1, outputChannels: 1, outputCount: 8,
                           gain: 0, targetGain: 1, ramp: 0.5)

        for pair in zip(result.output, result.output.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
        #expect(result.output[0] == 0.5)
        #expect(result.gain > 0.99)
    }
}
