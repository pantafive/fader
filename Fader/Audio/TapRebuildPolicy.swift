enum TapRebuildPolicy {
    static let firstRetry: Duration = .milliseconds(250)
    static let maxRetry: Duration = .seconds(4)

    enum BrokenTap: Equatable {
        case hold
        case keepPlaying
    }

    static func brokenTap(isAlive: Bool, isHeld: Bool) -> BrokenTap {
        isHeld || !isAlive ? .hold : .keepPlaying
    }

    /// Doubles from `firstRetry` per consecutive failure, capped at `maxRetry`.
    static func retryDelay(afterFailures failures: Int) -> Duration {
        let doublings = min(max(failures - 1, 0), 8)
        return min(firstRetry * (1 << doublings), maxRetry)
    }
}
