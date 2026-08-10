import Foundation

enum TrendDirection: String {
    case improving, stable, degrading

    var icon: String {
        switch self {
        case .improving: "arrow.up.right"
        case .stable: "arrow.right"
        case .degrading: "arrow.down.right"
        }
    }

    var color: String {
        switch self {
        case .improving: "green"
        case .stable: "blue"
        case .degrading: "red"
        }
    }
}

struct TrendResult: Identifiable {
    let metric: String
    let direction: TrendDirection
    let changePercent: Double
    let confidence: Double // 0-1 based on R²
    /// The window the regression was actually fitted over, e.g. "12d span, 24 reports".
    let period: String
    /// Every sample was identical, so R² is undefined and there is no trend to report.
    var isFlat: Bool = false
    var id: String {
        metric
    }
}

enum TrendAnalyzer {
    /// Analyze trend for a set of (date, value) samples.
    /// Uses simple linear regression on normalized timestamps.
    static func analyzeTrend(
        samples: [(date: Date, value: Double)],
        metric: String,
        lowerIsBetter: Bool = true,
        period: String = "recent"
    ) -> TrendResult? {
        guard samples.count >= 3 else { return nil }

        let sorted = samples.sorted { $0.date < $1.date }
        guard let first = sorted.first else { return nil }
        let base = first.date.timeIntervalSince1970

        // Normalize x to days from first sample
        let xs = sorted.map { ($0.date.timeIntervalSince1970 - base) / 86400 }
        let ys = sorted.map(\.value)

        let n = Double(xs.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map(*).reduce(0, +)
        let sumX2 = xs.map { $0 * $0 }.reduce(0, +)

        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n

        // R² for confidence
        let meanY = sumY / n
        let ssTotal = ys.map { ($0 - meanY) * ($0 - meanY) }.reduce(0, +)
        guard ssTotal > 0 else {
            // Every sample is identical: R² is 0/0, not 1. Report a flat series with
            // no confidence rather than a perfectly-fitted trend.
            return TrendResult(
                metric: metric,
                direction: .stable,
                changePercent: 0,
                confidence: 0,
                period: period,
                isFlat: true
            )
        }
        let ssResidual: Double = zip(xs, ys).map { x, y in
            let predicted = slope * x + intercept
            return (y - predicted) * (y - predicted)
        }.reduce(0, +)
        let r2 = 1 - (ssResidual / ssTotal)

        // Change as % of mean
        let totalDays = (xs.last ?? 1) - (xs.first ?? 0)
        guard totalDays > 0, meanY != 0 else {
            return TrendResult(metric: metric, direction: .stable, changePercent: 0, confidence: r2, period: period)
        }
        let totalChange = slope * totalDays
        let changePercent = (totalChange / meanY) * 100

        // Determine direction
        let direction: TrendDirection
        let threshold = 5.0 // 5% change threshold
        if abs(changePercent) < threshold || r2 < 0.1 {
            direction = .stable
        } else if (changePercent > 0 && !lowerIsBetter) || (changePercent < 0 && lowerIsBetter) {
            direction = .improving
        } else {
            direction = .degrading
        }

        return TrendResult(
            metric: metric,
            direction: direction,
            changePercent: changePercent,
            confidence: max(0, r2),
            period: period
        )
    }

    /// Human-readable description of the window a trend was actually fitted over.
    /// Derived from the real sample dates — never a placeholder.
    static func describePeriod(dates: [Date]) -> String {
        guard let earliest = dates.min(), let latest = dates.max() else { return "no data" }
        let days = Calendar.current.dateComponents([.day], from: earliest, to: latest).day ?? 0
        return days > 0 ? "\(days)d span, \(dates.count) reports" : "same day, \(dates.count) reports"
    }

    /// Analyze all key metrics from report summaries.
    /// Analyses every metric at once. Used by the PDF trend section and available to
    /// any caller that wants the full set rather than one metric at a time.
    static func analyzeAll(summaries: [ReportSummary]) -> [TrendResult] {
        guard summaries.count >= 3 else { return [] }
        let sorted = summaries.sorted { $0.date < $1.date }
        let period = describePeriod(dates: sorted.map(\.date))

        var results: [TrendResult] = []

        if let t = analyzeTrend(
            samples: sorted.map { (date: $0.date, value: $0.latencyAvg) },
            metric: "Avg Latency", lowerIsBetter: true, period: period
        ) {
            results.append(t)
        }

        if let t = analyzeTrend(
            samples: sorted.map { (date: $0.date, value: $0.latencyP95) },
            metric: "P95 Latency", lowerIsBetter: true, period: period
        ) {
            results.append(t)
        }

        if let t = analyzeTrend(
            samples: sorted.map { (date: $0.date, value: $0.throughputBps) },
            metric: "Throughput", lowerIsBetter: false, period: period
        ) {
            results.append(t)
        }

        if let t = analyzeTrend(
            samples: sorted.map { (date: $0.date, value: $0.jitterAvg) },
            metric: "Jitter", lowerIsBetter: true, period: period
        ) {
            results.append(t)
        }

        if let t = analyzeTrend(
            samples: sorted.map { (date: $0.date, value: $0.packetLossPercent) },
            metric: "Packet Loss", lowerIsBetter: true, period: period
        ) {
            results.append(t)
        }

        return results
    }
}
