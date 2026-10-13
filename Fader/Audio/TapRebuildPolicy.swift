/// Timing for rebuilding a tap that stopped working. A tap that is still
/// present keeps its app muted, so holding it while retries run means a short
/// silence; releasing it hands the app back to its native output at full
/// volume — painful on headphones whose only attenuation is Fader. The hold
/// stays bounded because a rebuild that never succeeds must not silence the
/// app for good.
enum TapRebuildPolicy {
    static let holdLimit: Duration = .seconds(10)
    static let firstRetry: Duration = .milliseconds(250)
    static let maxRetry: Duration = .seconds(4)

    enum BrokenTap: Equatable {
        case hold
        case release
    }

    static func brokenTap(failingSince: ContinuousClock.Instant, now: ContinuousClock.Instant) -> BrokenTap {
        now - failingSince < holdLimit ? .hold : .release
    }

    /// Doubles from `firstRetry` per consecutive failure, capped at `maxRetry`.
    static func retryDelay(afterFailures failures: Int) -> Duration {
        let doublings = min(max(failures - 1, 0), 8)
        return min(firstRetry * (1 << doublings), maxRetry)
    }
}
