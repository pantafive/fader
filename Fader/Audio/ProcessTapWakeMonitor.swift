import Foundation

/// One coalesced poller for every suspended process tap. HAL property reads are
/// synchronous IPC into coreaudiod, so they must never run on the main actor:
/// even a low-CPU wait there stalls AppKit's mouse-event loop.
@MainActor
final class ProcessTapWakeMonitor {
    static let shared = ProcessTapWakeMonitor()

    private final class WeakTap {
        weak var value: ProcessTap?

        init(_ value: ProcessTap) {
            self.value = value
        }
    }

    private var taps: [ObjectIdentifier: WeakTap] = [:]
    private var pollTask: Task<Void, Never>?
    /// Distinguishes the current poller from a cancelled predecessor. Without
    /// this, an old task can finish late, clear the new task's handle, and let
    /// later `watch` calls stack duplicate poll loops.
    private var pollGeneration: UInt = 0

    func watch(_ tap: ProcessTap) {
        taps[ObjectIdentifier(tap)] = WeakTap(tap)
        guard pollTask == nil else { return }
        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.pollGeneration == generation {
                    self.pollTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100), tolerance: .milliseconds(30))
                } catch {
                    break
                }
                guard let self else { break }
                taps = taps.filter { $0.value.value != nil }
                let candidates = taps.values.compactMap(\.value)
                guard !candidates.isEmpty else { break }

                // AudioObjectGetPropertyData blocks in a Mach IPC round-trip.
                // Keep that wait on a utility worker; awaiting it suspends this
                // task and leaves the main actor free to process UI events.
                let started = await Task.detached(priority: .utility) {
                    candidates.filter(\.hasRunningOutput)
                }.value
                guard !Task.isCancelled else { break }
                for tap in started {
                    tap.resumeAfterOutputStarted()
                }
            }
        }
    }

    func unwatch(_ tap: ProcessTap) {
        taps[ObjectIdentifier(tap)] = nil
        guard taps.isEmpty else { return }
        pollGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
    }
}
