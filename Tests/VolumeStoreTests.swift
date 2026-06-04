import Foundation
import Testing

@Suite("VolumeStore")
struct VolumeStoreTests {
    private func makeStore() -> (VolumeStore, UserDefaults) {
        let suite = "VolumeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (VolumeStore(defaults: defaults), defaults)
    }

    @Test("round-trips non-neutral entries")
    func roundTrip() {
        let (store, _) = makeStore()
        let entries = [
            "com.example.loud": AppVolume(volume: 0.3, isMuted: false),
            "com.example.muted": AppVolume(volume: 1.0, isMuted: true),
        ]
        store.save(entries)
        #expect(store.load() == entries)
    }

    @Test("drops neutral entries on save")
    func dropsNeutral() {
        let (store, _) = makeStore()
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
        let (store, _) = makeStore()
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
}
