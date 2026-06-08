import Testing

@Suite("VolumeTaper.gain")
struct VolumeTaperTests {
    @Test("endpoints map to silence and unity")
    func endpoints() {
        #expect(VolumeTaper.gain(position: 0) == 0)
        #expect(VolumeTaper.gain(position: 1) == 1)
    }

    @Test("clamps out-of-range positions")
    func clamps() {
        #expect(VolumeTaper.gain(position: -0.5) == 0)
        #expect(VolumeTaper.gain(position: 2) == 1)
    }

    @Test("midpoint sits well below linear −6 dB so the bottom of the travel breathes")
    func midpointTapered() {
        // Cube law: 0.5 → 0.125 (≈ −18 dB), not the 0.5 a linear map would give.
        #expect(VolumeTaper.gain(position: 0.5) == 0.125)
    }

    @Test("monotonically increasing across the travel")
    func monotonic() {
        var previous = VolumeTaper.gain(position: 0)
        for step in 1 ... 20 {
            let gain = VolumeTaper.gain(position: Float(step) / 20)
            #expect(gain > previous)
            previous = gain
        }
    }
}
