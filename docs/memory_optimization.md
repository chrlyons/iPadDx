# Memory Optimization — ReportStore & In-Memory Data

> **Status:** Implemented. `[TestReport]` replaced with `[ReportSummary]`, full reports loaded on demand.

## Problem

`ReportStore` loaded every report into memory on app launch and kept them there for the app's lifetime. Each `TestReport` is heavy — raw latency samples, full device info, system metrics, nested result structs. On top of that, SwiftData caches `ReportEntity` objects with `rawJSON: Data?` blobs.

Every report lived in memory three times:

```
1. ReportEntity          — SwiftData cache (denormalized fields + rawJSON blob)
2. ReportEntity.rawJSON  — full JSON-encoded TestReport (~2-5KB per report)
3. TestReport            — decoded struct in reports: [TestReport] array
```

With bridge transports multiplying runs (5 devices x 5 bridges = 100 reports per session), this grows fast.

---

## Solution

### ReportSummary

File: `iPadDx/Models/ReportSummary.swift`

Lightweight struct (~300 bytes) holding only what list/analytics views need. Constructed directly from `ReportEntity` columns — no JSON decoding.

```swift
struct ReportSummary: Identifiable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let overallGrade: String
    let source: String

    // Device info (both sides)
    let localName, localModel, localModelNumber, localOS, localChip: String
    let remoteName, remoteModel, remoteModelNumber, remoteOS, remoteChip: String

    // All key metrics (for analytics aggregation)
    let latencyMin, latencyMax, latencyAvg, latencyMedian, latencyP95: Double
    let latencySampleCount: Int
    let throughputBps: Double
    let throughputBytes: Int
    let throughputDuration: Double
    let jitterAvg, jitterMax: Double
    let jitterSampleCount: Int
    let packetLossSent, packetLossReceived: Int
    let packetLossPercent, packetLossDuration: Double
    let loadBaselineAvg, loadUnderLoadAvg, loadDegradation: Double
    let loadSampleCount: Int

    let bridgeTransport: String

    // Computed: localChipFamily, remoteChipFamily, localDisplayModel, remoteDisplayModel, pairLabel
}
```

Two initializers:
- `init(from entity: ReportEntity)` — reads denormalized columns, no rawJSON decode
- `init(from report: TestReport, source:)` — for inline creation when saving

### ReportStore

```swift
class ReportStore {
    var summaries: [ReportSummary] = []  // lightweight, always in memory

    func loadAll() {
        // Reads ReportEntity columns → ReportSummary. No JSON decode.
        summaries = entities.map { $0.toSummary() }
    }

    func loadFullReport(id: UUID) -> TestReport? {
        // On-demand: fetches entity by ID, decodes rawJSON
    }

    func loadFullReports(ids: Set<UUID>) -> [TestReport] {
        ids.compactMap { loadFullReport(id: $0) }
    }
}
```

---

## View Migration

| View | Before | After |
|---|---|---|
| **ReportListView** | `ForEach(store.reports)` | `ForEach(store.summaries)` — loads full report only for export/compare |
| **ReportDetailView** | `let report: TestReport` | `let reportID: UUID` + `.task { report = store.loadFullReport(id:) }` with loading indicator |
| **ReportAnalyticsView** | `store.reports` for all aggregation | `store.summaries` — all metrics available on summary |
| **ReportComparisonView** | Takes two `TestReport` directly | Caller loads full reports via `loadFullReports(ids:)` before presenting |
| **ConductorDashboardView** | `completedReports: [TestReport]` | Unchanged — transient, bounded by queue size |
| **Export** | Operated on `[TestReport]` already in memory | `loadFullReports(ids:)` at export time |

---

## What's Not in Memory Anymore

- Raw latency samples (`[Double]`, ~800 bytes per report)
- Full `TestSuiteResults` nested structs
- `SystemMetricsResult`, `ResponderMetricsResult`
- `errors: [String]?`, `skippedPhases: [String]?`

These are only loaded when a user opens a specific report's detail view or exports.

---

## Other In-Memory State — Unchanged

| Holder | What It Stores | Cap | Verdict |
|---|---|---|---|
| `LogStore.entries` | Log messages | 5,000 | Fine |
| `DiagnosticMetrics.latencyHistory` | RTT samples | 120 | Fine |
| `DiagnosticMetrics.connectionLog` | Connection events | 50 | Fine |
| `ConductorService.eventLog` | Conductor events | 100 | Fine |
| `ConductorService.completedReports` | Current run results | Queue size | Fine — transient |
| `TestSuiteRunner` internal buffers | Pending pongs, CPU samples | Test duration | Fine — cleared after test |

---

## Memory Impact

Assuming 200 stored reports:

| | Before | After |
|---|---|---|
| `[TestReport]` in memory | 200 x ~3KB = ~600KB | 0 (removed) |
| `[ReportSummary]` in memory | 0 | 200 x ~300B = ~60KB |
| SwiftData cache | ~600KB | ~600KB (unchanged) |
| On-demand loads | 0 | 1-2 at a time = ~6KB |
| **Total** | **~1.2MB** | **~660KB** |

At 1,000 reports: ~6MB saved. `loadAll()` at launch is faster — reads SQLite columns into a flat struct instead of decoding JSON blobs.

---

## Files

| File | Change |
|---|---|
| `Models/ReportSummary.swift` | New file — lightweight summary struct + BridgeComparisonRow |
| `Models/ReportEntity.swift` | Added `toSummary() -> ReportSummary` |
| `Services/ReportStore.swift` | `summaries` replaces `reports`, `loadFullReport(id:)`, updated queries |
| `Views/ReportListView.swift` | Uses summaries, loads full reports for export/compare |
| `Views/ReportDetailView.swift` | Loads full report on demand via reportID |
| `Views/ReportAnalyticsView.swift` | All aggregation on summaries |
| `Views/ReportComparisonView.swift` | Receives full reports from caller |
| `Views/ConductorDashboardView.swift` | Unchanged (uses transient completedReports) |
