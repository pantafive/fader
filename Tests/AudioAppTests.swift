import CoreAudio
import Testing

@Suite("AudioApp coalescing")
struct AudioAppTests {
    @Test("duplicate bundle IDs merge every HAL process without trapping")
    func duplicateBundlesMerge() throws {
        let first = AudioApp(
            id: 40,
            bundleID: "com.example.player",
            name: "Player copy B",
            objectIDs: [9, 7],
            isPlaying: false,
            isRecording: true
        )
        let second = AudioApp(
            id: 20,
            bundleID: "com.example.player",
            name: "Player copy A",
            objectIDs: [7, 3],
            isPlaying: true,
            isRecording: false
        )

        let merged = try #require(AudioApp.coalescedByBundleID([first, second]).first)

        #expect(merged.id == 20)
        #expect(merged.name == "Player copy A")
        #expect(merged.objectIDs == [3, 7, 9])
        #expect(merged.isPlaying)
        #expect(merged.isRecording)
    }

    @Test("different bundles retain their first-seen order")
    func distinctBundlesKeepOrder() {
        let first = AudioApp(
            id: 1, bundleID: "com.example.first", name: "First",
            objectIDs: [1], isPlaying: false, isRecording: false
        )
        let second = AudioApp(
            id: 2, bundleID: "com.example.second", name: "Second",
            objectIDs: [2], isPlaying: false, isRecording: false
        )

        #expect(AudioApp.coalescedByBundleID([first, second]).map(\.bundleID) == [
            "com.example.first", "com.example.second",
        ])
    }
}
