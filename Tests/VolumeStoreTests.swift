import Foundation
import Testing

@Suite("VolumeStore")
struct VolumeStoreTests {
    private func makeStore() -> VolumeStore {
        let suite = "VolumeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return VolumeStore(defaults: defaults)
    }

    @Test("round-trips non-neutral entries")
    func roundTrip() {
        let store = makeStore()
        let entries = [
            "com.example.loud": AppVolume(volume: 0.3, isMuted: false),
            "com.example.muted": AppVolume(volume: 1.0, isMuted: true),
        ]
        store.save(entries)
        #expect(store.load() == entries)
    }

    @Test("drops neutral entries on save")
    func dropsNeutral() {
        let store = makeStore()
        store.save([
            "com.example.neutral": AppVolume(volume: 1.0, isMuted: false),
            "com.example.quiet": AppVolume(volume: 0.5, isMuted: false),
        ])
        let loaded = store.load()
        #expect(loaded["com.example.neutral"] == nil)
        #expect(loaded["com.example.quiet"] == AppVolume(volume: 0.5, isMuted: false))
    }

    @Test("empty defaults loads empty dictionary")
    func emptyLoad() {
        let store = makeStore()
        #expect(store.load().isEmpty)
    }
}

@Suite("AppVolume")
struct AppVolumeTests {
    @Test("neutrality")
    func neutrality() {
        #expect(AppVolume(volume: 1.0, isMuted: false).isNeutral)
        #expect(!AppVolume(volume: 0.99, isMuted: false).isNeutral)
        #expect(!AppVolume(volume: 1.0, isMuted: true).isNeutral)
    }

    /// A route forces a tap even at unity gain, so a routed-at-unity entry must
    /// not read as neutral — otherwise VolumeStore.save drops it and the route
    /// is silently lost on the next write.
    @Test("a route keeps a unity entry non-neutral")
    func routedIsNotNeutral() {
        #expect(!AppVolume(volume: 1.0, isMuted: false, outputDeviceUIDs: ["dev-uid"]).isNeutral)
    }

    @Test("routed devices survive a save round-trip, order kept")
    func routedRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let store = VolumeStore(defaults: defaults)
        store.save(["com.app": AppVolume(volume: 1.0, isMuted: false, outputDeviceUIDs: ["dev-a", "dev-b"])])
        #expect(store.load()["com.app"]?.outputDeviceUIDs == ["dev-a", "dev-b"])
    }

    /// The pre-multi-route blob stored a single `outputDeviceUID`; decoding must
    /// fold it into the list rather than throw and lose every saved volume.
    @Test("a legacy single-route entry decodes into the list")
    func legacyRouteDecodes() throws {
        let json = #"{"com.app":{"volume":1,"isMuted":false,"outputDeviceUID":"dev-uid"}}"#
        let decoded = try JSONDecoder().decode([String: AppVolume].self, from: Data(json.utf8))
        #expect(decoded["com.app"]?.outputDeviceUIDs == ["dev-uid"])
    }
}
