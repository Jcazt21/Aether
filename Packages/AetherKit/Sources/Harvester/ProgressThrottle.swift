struct ProgressThrottle {
    private let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration = .milliseconds(100)) { self.interval = interval }

    mutating func shouldEmit(now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}

/// Exponentially smoothed throughput (bytes/s) — stable readout, no per-sample array.
struct ThroughputMeter {
    private var lastSample: ContinuousClock.Instant?
    private(set) var bytesPerSecond: Double = 0

    mutating func add(_ bytes: Int, at now: ContinuousClock.Instant = .now) {
        defer { lastSample = now }
        guard let last = lastSample else { return }
        let seconds = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
        guard seconds > 0 else { return }
        let instant = Double(bytes) / seconds
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
    }
}
