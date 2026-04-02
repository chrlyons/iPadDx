# Bridge Transport — ReportStore & In-Memory Changes

> **Status:** Implemented. All query methods, export formats, and view filters are in place.

---

## Architecture

`ReportStore` uses a dual-layer model:

```
ReportStore
├── var summaries: [ReportSummary]    ← lightweight, always in memory
├── SwiftData ModelContext
│   └── ReportEntity                  ← persistent storage, denormalized metrics + rawJSON
├── On-Demand Loading
│   ├── loadFullReport(id:)           ← decodes rawJSON for detail/export
│   └── loadFullReports(ids:)         ← batch loading
├── Queries (on summaries)
│   ├── summaries(forChipPair:bridge:)
│   ├── summaries(forBridge:)
│   ├── availableBridgeTransports()
│   ├── bridgeComparison(local:remote:)
│   └── reports(fromSource:bridge:)   ← SwiftData compound predicate
└── Exports
    ├── exportCSV(for:)               ← single report, bridge line in header
    ├── exportSummaryCSV(for:)        ← batch, bridge column
    └── exportAnalyticsCSV(for:)      ← bridge comparison + per-pair bridge sections

ConductorService
└── var completedReports: [TestReport] ← transient, current queue run
```

---

## ReportEntity Schema

```swift
@Model
class ReportEntity {
    // ... existing fields ...
    var bridgeTransport: String = "native"
}
```

- Column default handles migration — old records get `"native"`
- `init(from:)` maps `report.bridgeTransport ?? "native"`
- `toSummary()` reads column directly (no JSON decode)

---

## Query Methods

All queries operate on the in-memory `summaries` array (lightweight `ReportSummary` structs):

```swift
// Filter by bridge
func summaries(forBridge bridge: String) -> [ReportSummary]

// Filter by chip pair with optional bridge
func summaries(forChipPair local: String, remote: String, bridge: String? = nil) -> [ReportSummary]

// Distinct bridges in store
func availableBridgeTransports() -> [String]

// Compare metrics across bridges for a device pair
func bridgeComparison(local: String, remote: String) -> [BridgeComparisonRow]

// SwiftData compound predicate query
func reports(fromSource source: String, bridge: String? = nil) -> [TestReport]
```

### BridgeComparisonRow

```swift
struct BridgeComparisonRow: Identifiable {
    let bridge: String
    let reportCount: Int
    let avgLatency: Double
    let avgJitter: Double
    let avgPacketLoss: Double
    let avgThroughput: Double
    let avgGradeScore: Double  // 0-12 scale (Excellent=12, Good=9, Fair=6, Poor=3)
}
```

---

## CSV Export Changes

### Single Report (`exportCSV`)

Bridge transport line added to header section:

```
iPadDx Test Report
Date,2026-03-31T...
Duration,42.5s
Overall Grade,Good
Bridge Transport,cordova
```

### Summary CSV (`exportSummaryCSV`)

"Bridge Transport" column added between Remote OS and Grade:

```csv
Date,Local Name,...,Remote OS,Bridge Transport,Grade,Duration (s),...
```

### Analytics CSV (`exportAnalyticsCSV`)

**Overview section** — bridge transports line:
```
Total Reports,12
Bridge Transports,"native, cordova"
```

**Bridge Comparison section** (only when multiple bridges present):
```csv
Bridge Comparison
Bridge,Reports,Avg Latency (ms),P95 Latency (ms),Throughput (MB/s),Avg Jitter (ms),Packet Loss (%),Load Degradation (%),Excellent,Good,Fair,Poor
native,6,4.5,8.2,45.2,1.2,0.3,12.1,5,1,0,0
cordova,6,13.1,22.4,38.7,3.8,0.8,28.3,2,3,1,0
```

**Per-Pair Breakdown** — bridge column added when multiple bridges:
```csv
Pair,Bridge,Count,Avg Latency (ms),...
M4 vs M2,native,1,3.8,...
M4 vs M2,cordova,1,11.2,...
```

**Per-Chip Summary** — bridge dimension added when multiple bridges:
```csv
Chip,Bridge,As Sender (count),Sender Avg Latency (ms),...
M4,native,3,4.2,...
M4,cordova,3,12.1,...
```

When only native bridge exists, these sections omit the Bridge column (backward compatible format).

---

## PDF Analytics Report

`AnalyticsReportRenderer` adds a "Bridge Overhead Analysis" section when multiple bridges are present:

- **Bridge comparison table** — per-bridge summary with delta vs native baseline ("+8.6ms latency")
- **Per-pair bridge table** — each device pair broken down by bridge with most common grade

---

## ConductorService

- `completedReports: [TestReport]` — each report carries `bridgeTransport` from the `TestRun` that produced it
- Event log messages include bridge tag: `"A → B [cordova]: Starting remote run"`
- Re-run failed preserves `bridgeTransport` when re-queuing: creates new `TestRun` with original pair + bridge

---

## View Integration

- **ReportListView** — bridge filter picker (segmented, only shown when multiple bridges exist), bridge tag on non-native report rows
- **ReportDetailView** — bridge transport badge in grade header
- **ReportAnalyticsView** — bridge filter dropdown, bridge overhead comparison chart with delta vs native
- **ReportComparisonView** — shows bridge transport in report headers, highlights when bridges differ
- **ConductorDashboardView** — bridge tag on queue items and completed results

---

## Migration

1. Old `ReportEntity` records get `bridgeTransport = "native"` (column default)
2. Old `rawJSON` decodes `bridgeTransport` to `nil` — all queries use `?? "native"` fallback
3. Old `orchestrateTest` messages lack `bridgeTransport` — parameter has default value `"native"`
4. No data loss, no re-processing needed

---

## Files

| File | What Changed |
|---|---|
| `Models/TestReport.swift` | `let bridgeTransport: String?` field |
| `Models/ReportEntity.swift` | `bridgeTransport` column, `toSummary()` |
| `Models/ReportSummary.swift` | `BridgeComparisonRow` struct |
| `Services/ReportStore.swift` | Query methods, export formats, bridge columns |
| `Services/ConductorService.swift` | Event log bridge labels, TestRun preservation |
| `Services/AnalyticsReportRenderer.swift` | PDF bridge overhead section |
| `Views/ReportDetailView.swift` | Bridge badge in header |
| `Views/ReportListView.swift` | Bridge filter picker, badge on rows |
| `Views/ReportAnalyticsView.swift` | Bridge filter, overhead chart |
| `Views/ReportComparisonView.swift` | Bridge info in headers |
| `Views/ConductorDashboardView.swift` | Bridge tag on queue items and results |
