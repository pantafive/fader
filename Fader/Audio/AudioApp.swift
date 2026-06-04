import AppKit
import CoreAudio

/// A running application that owns one or more HAL audio processes.
/// Browsers and Electron apps play audio from helper processes; they group
/// under the responsible application here.
struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let bundleID: String
    let name: String
    let objectIDs: [AudioObjectID]
    let isPlaying: Bool
    let isRecording: Bool

    /// App icon resolved through NSRunningApplication; cheap, AppKit caches it.
    @MainActor
    var icon: NSImage {
        NSRunningApplication(processIdentifier: id)?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
