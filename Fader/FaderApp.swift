import SwiftUI

@main
struct FaderApp: App {
    @State private var engine: MixerEngine

    init() {
        // Start at launch, not on first popover open — saved volumes must
        // apply to running apps immediately.
        let engine = MixerEngine()
        engine.start()
        _engine = State(initialValue: engine)
    }

    var body: some Scene {
        MenuBarExtra("Fader", systemImage: "slider.horizontal.3") {
            MixerView()
                .environment(engine)
        }
        .menuBarExtraStyle(.window)
    }
}
