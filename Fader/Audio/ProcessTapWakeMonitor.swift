import Foundation

/// One coalesced poller for every suspended process tap. A direct read of the
/// handful of watched process flags is much cheaper than keeping each aggregate
/// device and real-time IO callback running around the clock.
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

    func watch(_ tap: ProcessTap) {
        taps[ObjectIdentifier(tap)] = WeakTap(tap)
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50), tolerance: .milliseconds(20))
                } catch {
                    break
                }
                guard let self else { break }
                let candidates = taps.values.compactMap(\.value)
                for tap in candidates {
                    tap.resumeIfOutputStarted()
                }
                taps = taps.filter { $0.value.value != nil }
                if taps.isEmpty { break }
            }
            self?.pollTask = nil
        }
    }

    func unwatch(_ tap: ProcessTap) {
        taps[ObjectIdentifier(tap)] = nil
        guard taps.isEmpty else { return }
        pollTask?.cancel()
        pollTask = nil
    }
}
