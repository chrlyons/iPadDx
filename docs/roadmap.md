# iPadDx Roadmap

Feature roadmap for iPadDx — an iPad-to-iPad Bonjour connection diagnostic tool. These improvements target anyone testing iPads and local networks: school IT administrators, QA teams, enterprise mobility engineers, clinical device coordinators, developers building peer-to-peer apps, and network infrastructure teams.

**Status:** 12 of 16 features implemented (12 sections below are marked DONE; 4 remain).

> **2026-08-10 — reconciled against the code.** An audit found that several sections marked DONE described work the code did not actually do. Those gaps have since been closed in the source (real throughput payloads, real load generation, grading that excludes phases that produced no samples, phases that can fail, working cancellation, honest bridge labelling). This document was then re-checked section by section: every status marker and every "Implemented" note below was verified against the current source, and where a shipped feature is narrower than the original plan the limit is now stated instead of omitted. The status line previously read "13 of 16"; the file has only ever had 12 DONE markers.

---

## 1. Test Cancellation — DONE

> **Implemented:** `cancelRequested` on `TestSuiteRunner`, checked in the warm-up loop, in every phase loop (latency burst, throughput, jitter, packet loss, latency-under-load, heavy load) and between phases in `runFullSuite()`. `cancel()` also clears `loadGeneratorActive` so an in-flight load stream stops immediately, resumes a phase blocked waiting for the peer's throughput ack, and sends `testSuiteStatus(running: false)`.
>
> A cancelled run breaks out of the phase sequence and still builds a report from everything gathered so far: phases still `.pending` become `.skipped` and are listed in `skippedPhases`, `"Test cancelled by user — this is a partial report"` is appended to the report's error list, and the run ends in `.failed("Cancelled by user")` with the partial report returned.
>
> Cancel paths: the Cancel button in `TestSuiteView`'s running state calls `runner.cancel()` directly. `ConductorService.cancelQueue()` explicitly cancels the conductor's own `selfRunner` (cancelling the wrapper `Task` is not enough — the runner's pacing delays are `try? await Task.sleep`, which throws instantly in a cancelled task and would let the suite race through its remaining phases), cancels the active run tasks, and sends `orchestrationCancel` to every agent currently testing. `AgentService.cancelTest()` calls `testRunner?.cancel()` before tearing the partner connection down, and reports `cancelled` to the conductor, which now handles that phase and returns the agent to idle. An agent cancelled mid-suite still sends its partial report ("Cancelled — partial report sent") and the conductor stores it.
>
> **Not done:** a cancelled *conductor self-run* is logged and discarded rather than stored (`executeSelfRun` only appends a report when `!runner.cancelRequested`). In standalone mode the partial report stays on `runner.lastReport` but the view shows the failed/cancelled card, which has a Retry button and no Save. There is no per-pair cancel in the conductor UI — the Cancel button cancels the whole queue, so an individual stuck pair cannot be abandoned while the rest continues. `DiagnosticEngine` has no cancel forwarding — every cancel path calls the runner directly.

**Problem:** Once a test suite starts, there's no way to stop it. The heavy load phase alone runs for 15 seconds. Users are stuck watching a failing or irrelevant test, and in conductor mode a stuck test blocks the entire queue.

**Who benefits:** Everyone — this is basic usability.

**Implementation** (original plan; the flag shipped as `cancelRequested` and `cancel()` does more than this sketch — see the note above):

`TestSuiteRunner` needs a cancellation mechanism. Each phase runner (`runLatencyBurst`, `runThroughputTest`, etc.) has tight polling loops that currently ignore `Task.isCancelled`.

```swift
// TestSuiteRunner.swift — add property
private var cancelTask: Bool = false

func cancel() {
    cancelTask = true
    state = .failed("Cancelled by user")
}
```

Each phase loop needs a bail-out check:

```swift
// Example: runLatencyBurst
for i in 0..<count {
    guard !cancelTask else { return }
    connectionManager.send(.testPing(...))
    try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
}
```

**Files to modify:**
- `TestSuiteRunner.swift` — add `cancel()` method, check `cancelTask` in every phase loop and between phases in `runFullSuite()`
- `TestSuiteView.swift` — add Cancel button (visible when `runner.state == .running`)
- `DiagnosticEngine.swift` — forward cancel to runner if active
- `AgentService.swift` — handle `orchestrationCancel` by calling `runner.cancel()`
- `ConductorService.swift` — cancel button per-pair in queue UI, sends `orchestrationCancel`

**Edge cases:**
- Throughput test: responder may still be receiving chunks after cancel — send a `testSuiteStatus(running: false)` immediately
- Report generation: cancelled tests should produce a partial report (phases completed so far) rather than nil, so the data isn't lost — done
- Conductor queue: cancelled pair should be marked failed and the next pair should start — **not** how it works; cancelling stops the entire queue (remaining runs are dropped, active runs cancelled) rather than skipping one pair

---

## 2. Connection Drop Root Cause Detection — DONE

> **Implemented:** `DisconnectReason` enum (8 cases) and `DisconnectEvent` (timestamp, reason, detail, uptime at disconnect) in `DiagnosticMetrics`.
>
> `ConnectionManager.classifyError()` pattern-matches the real `NWError` cases instead of searching the error's description for substrings — `.posix` maps `ECONNREFUSED` → `.connectionRefused`, `ETIMEDOUT` → `.keepaliveTimeout`, `ENETDOWN`/`ENETUNREACH`/`EHOSTUNREACH`/`ENETRESET` → `.pathChanged`, `ECONNRESET`/`ECONNABORTED`/`EPIPE`/`ENOTCONN` → `.remoteDisconnect`; `.tls` → `.tlsError`; everything else → `.networkError`. `describeError()` produces the human-readable detail string.
>
> `logDisconnect` is now actually driven: every path that loses a connection (transport `.failed`, transport `.disconnected`, receive EOF, receive error) fires the new `ConnectionManager.onDisconnect(reason, detail)` callback, which `DiagnosticEngine.start()` wires to `DiagnosticMetrics.logDisconnect`. That callback is the sole writer of `disconnectionCount` and `disconnectHistory`, so ordinary teardown (`DiagnosticEngine.stop()` on a mode change) no longer counts as a disconnect. History is bounded to the last 50 events; the count stays the authoritative total.
>
> `lastDisconnectReason` is tracked per connection and used by `BonjourService` to distinguish "failed (TLS error)" from "timed out" in the connect status message. The dashboard health card shows the last five disconnect events with a reason icon, colour, detail and uptime, labelled "last 5 of N" when more have occurred.
>
> **Not done:** there is no `NWPath`-based detection — `.pathChanged` is inferred from POSIX network errors, not from a path handler observing an unsatisfied path. Disconnect events are not carried into `TestReport`.

**Problem:** `DiagnosticMetrics.disconnectionCount` increments on disconnect, but the *reason* is lost. Users see "disconnected 3 times" but can't tell if it was a network path change (benign), TLS error (config issue), keepalive timeout (device sleeping), or user action.

**Who benefits:** Network admins diagnosing intermittent connectivity, QA teams reproducing disconnect bugs, anyone troubleshooting flaky peer-to-peer links.

**Implementation:**

Define structured disconnect reasons:

```swift
// Models/ConnectionEvent.swift or DiagnosticMetrics.swift
enum DisconnectReason: String, Codable {
    case userInitiated      // user tapped disconnect
    case remoteDisconnect   // peer sent .disconnect message
    case keepaliveTimeout   // no pong received within threshold
    case pathChanged        // NWPath changed (e.g., Wi-Fi → cellular)
    case tlsError           // TLS handshake or session error
    case connectionRefused  // POSIX errno 61
    case networkError       // other NWError
    case unknown
}
```

Capture the reason at each disconnect site:

- `BonjourService.disconnect()` → `.userInitiated`
- `BonjourService.handleRemoteDisconnect()` → `.remoteDisconnect`
- `NativeTransport` state handler `.failed(error)` → parse NWError into `.tlsError`, `.connectionRefused`, `.networkError`
- `NativeTransport` path handler → `.pathChanged` when path becomes unsatisfied
- `ConnectionManager.onConnectionLost` → carry reason from transport

Store in metrics:

```swift
// DiagnosticMetrics.swift
struct DisconnectEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let reason: DisconnectReason
    let detail: String  // e.g., "POSIXErrorCode 61" or "path unsatisfied"
    let uptimeAtDisconnect: TimeInterval
}
var disconnectHistory: [DisconnectEvent] = []
```

**Files to modify:**
- `DiagnosticMetrics.swift` — add `DisconnectReason` enum, `DisconnectEvent` struct, `disconnectHistory` array
- `NativeTransport.swift` — propagate error details through `onStateChange`
- `ConnectionManager.swift` — capture reason from transport, pass to metrics
- `BonjourService.swift` — tag each disconnect path with reason
- `DiagnosticDashboardView.swift` — show disconnect history with reason badges in connection log
- `TestReport.swift` — optionally include disconnect events during test window

---

## 3. Latency Distribution Histogram — DONE

> **Implemented:** `LatencyBurstResult` extended with p5/p25/p75/p99, a `[HistogramBucket]` array and `anomalyCount` — all optional and decoded with `decodeIfPresent`, so reports written before these fields existed still load. `buildHistogram()` creates 20 equal-width buckets spanning min→max (it returns an empty array when every sample is identical, since there is no range to bucket).
>
> The supporting statistics were corrected at the same time: `percentile()` linearly interpolates between the two bracketing samples instead of indexing `Int(count * p)` (which returned the 96th smallest value for p95 over 100 samples), and `median()` averages the two central values on an even count.
>
> `ReportDetailView` draws the distribution as a `BarMark` chart coloured by threshold (green <10ms, blue <30ms, orange <100ms, red above). Bars are drawn from numeric `xStart`/`xEnd` bucket edges rather than category labels, and the axis label precision adapts to the bucket width — buckets are frequently narrower than 1ms, and rounding their start to a whole number used to collapse several distinct buckets onto one label. Below the chart: a bucket-count/range caption, a P5/P25/P75/P99 grid, and the anomaly count when it is non-zero.
>
> **Not done:** analytics does not aggregate histograms across reports, and the PDF export contains no histogram.

**Problem:** Reports show min/max/avg/median/p95 but not the shape of the distribution. A connection that's "always 20ms" and one that's "10ms half the time, 50ms the other half" both show avg=20ms. The bimodal case indicates interference or competing traffic — a completely different diagnosis.

**Who benefits:** Network engineers analyzing connection quality, anyone comparing "stable vs. unstable" connections.

**Implementation:**

Add percentile and histogram computation to latency results:

```swift
// TestReport.swift — extend LatencyBurstResult
struct LatencyBurstResult: Codable {
    // Existing
    let min, max, avg, median, p95: Double
    let sampleCount: Int
    let samples: [Double]

    // New
    let p5, p25, p75, p99: Double
    let histogram: [HistogramBucket]  // optional, nil for old reports
}

struct HistogramBucket: Codable {
    let rangeStart: Double  // ms
    let rangeEnd: Double
    let count: Int
}
```

Build histogram with adaptive bucket sizing:

```swift
static func buildHistogram(samples: [Double], bucketCount: Int = 20) -> [HistogramBucket] {
    let sorted = samples.sorted()
    let min = sorted.first ?? 0
    let max = sorted.last ?? 0
    let bucketWidth = (max - min) / Double(bucketCount)
    // ... bucket assignment
}
```

**UI:** Add a histogram chart to `ReportDetailView` in the Latency Burst section. Use SwiftUI `Chart` with `BarMark` — each bar is a bucket, colored by threshold (green <10ms, blue <30ms, orange <100ms, red >100ms).

**Files to modify:**
- `TestSuiteRunner.swift` — compute percentiles and histogram in `runLatencyBurst()`
- `TestReport.swift` — add fields to `LatencyBurstResult` (with backward-compatible decoding)
- `ReportDetailView.swift` — add histogram chart
- `ReportAnalyticsView.swift` — aggregate histograms across reports for trend analysis
- `AnalyticsReportRenderer.swift` — add histogram to PDF export

---

## 4. Auto-Retry Failed Pairs in Conductor Mode — DONE

> **Implemented:** `maxRetries` (default 2), `retryDelay` (default 5s) and a per-`TestRun` `retryCount` on `ConductorService`. `handleRunFailure()` waits `retryDelay`, re-executes the run and increments the count, or records the final failure once the budget is spent.
>
> It now has real call sites, which it previously did not: `executeSelfRun` calls it when the conductor's own suite produces no report, and `executeRemoteRun` calls it when the controller agent times out or its device disconnects. `ConductorDashboardView` shows an `n/maxRetries` retries badge on each failed run and a "Re-run N Failed" button that re-queues them while preserving the results already on screen.
>
> **Deliberately not retried** — these failures are not transient, so they go straight to `failedRuns`: a bridge that failed to initialise (`BridgeRegistry.isBridgeHealthy`), a bridge that either device did not advertise (`validateBridgeSupport`), a non-native bridge on a run with the conductor itself as an endpoint, a device missing from the fleet, an unencodable config, and runs that could never be scheduled because their devices never became available.
>
> **Not done:** `maxRetries` and `retryDelay` are only settable in code — there is still no "Auto-retry failed pairs" toggle or retry-count control in the queue settings UI.

**Problem:** Transient failures (AWDL flake, thermal pause, brief Wi-Fi dropout) fail a test pair permanently. The user must manually identify and re-queue them. When running 30+ pairs overnight, this defeats the purpose of automation.

**Who benefits:** Anyone running fleet tests — school IT doing nightly validation, QA teams running regression matrices.

**Implementation:**

Add retry configuration and automatic re-queue:

```swift
// ConductorService.swift
var maxRetries: Int = 2
var retryDelay: TimeInterval = 5  // seconds between retries
private var retryCount: [UUID: Int] = [:]  // TestRun.id → attempt count

private func shouldRetry(_ run: TestRun) -> Bool {
    let attempts = retryCount[run.id, default: 0]
    return attempts < maxRetries
}
```

After a run fails in `executeRemoteRun` or `executeSelfRun`:

```swift
if shouldRetry(run) {
    retryCount[run.id, default: 0] += 1
    let attempt = retryCount[run.id]!
    log("Retrying \(run.label) (attempt \(attempt)/\(maxRetries))", level: .warning)
    try? await Task.sleep(nanoseconds: UInt64(retryDelay) * 1_000_000_000)
    // Re-queue by re-executing
    await executeRun(run)
} else {
    failedRuns.append(run)
    log("\(run.label) failed after \(maxRetries) retries", level: .error)
}
```

**UI:** Add retry count badge on failed runs in `ConductorDashboardView`. Add a toggle in queue settings: "Auto-retry failed pairs (up to N times)".

**Files to modify:**
- `ConductorService.swift` — add retry logic, retry count tracking, configurable max retries
- `ConductorDashboardView.swift` — retry count badge, settings toggle

---

## 5. Live Responder Metrics During Test — DONE

> **Implemented:** New `liveMetrics(cpu:memoryMB:thermalState:timestamp:)` message case. `DiagnosticEngine` starts `startMetricsBroadcast()` when it receives `testSuiteStatus(running: true)` and cancels it on `running: false` (and in `stop()`), broadcasting a `SystemMonitor.snapshot()` every 2s while a remote test is in progress. The controller stores samples via `DiagnosticMetrics.appendRemoteMetrics` in `remoteMetricsHistory`, bounded to the last 100. The dashboard peer-info card shows a live badge with the responder's most recent CPU (coloured against `SystemMonitor`'s thresholds), memory footprint and thermal state.
>
> **Not done:** the live samples are not written into `TestReport` and are not overlaid on the report's latency chart — the report still carries only the post-test `responderMetrics` summary (peak/avg CPU, peak memory, worst thermal state, battery drain).

**Problem:** Responder-side CPU, memory, and thermal state only arrive in `responderMetrics` after the test completes. If the responder was thermal-throttled during phase 3, you can't correlate that with the latency spike you saw — you only learn about it after the fact.

**Who benefits:** Developers diagnosing app performance under load, QA teams identifying which device in a pair is the bottleneck.

**Implementation:**

Add a periodic metrics broadcast from the responder during tests:

```swift
// DiagnosticMessage.swift — new case
case liveMetrics(cpu: Double, memoryMB: Double, thermalState: String, timestamp: TimeInterval)
```

On the responder side, `DiagnosticEngine` starts a metrics broadcast loop when a test begins:

```swift
// DiagnosticEngine.swift
private func startMetricsBroadcast() {
    metricsBroadcastTask = Task {
        while !Task.isCancelled {
            let snap = SystemMonitor.snapshot()
            connectionManager.send(.liveMetrics(
                cpu: snap.cpuUsage,
                memoryMB: snap.memoryUsedMB,
                thermalState: SystemMonitor.thermalStateString(snap.thermalState),
                timestamp: Date().timeIntervalSince1970
            ))
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // every 2s
        }
    }
}
```

On the controller side, store live metrics samples and correlate with latency:

```swift
// DiagnosticMetrics.swift
struct RemoteMetricsSample {
    let timestamp: Date
    let cpu: Double
    let memoryMB: Double
    let thermalState: String
}
var remoteMetricsHistory: [RemoteMetricsSample] = []
```

**UI:** Add a "Remote Device" section to the test-in-progress view showing live CPU/thermal. In the report, overlay responder thermal state changes on the latency timeline.

**Files to modify:**
- `DiagnosticMessage.swift` — add `liveMetrics` case
- `DiagnosticEngine.swift` — start/stop metrics broadcast loop during test
- `DiagnosticMetrics.swift` — add `remoteMetricsHistory`
- `TestSuiteRunner.swift` — handle incoming `liveMetrics` messages, store samples
- `TestReport.swift` — optionally include remote metrics timeline
- `DiagnosticDashboardView.swift` — show live remote metrics during test
- `ReportDetailView.swift` — overlay remote metrics on latency chart

---

## 6. Device Location Tagging

**Problem:** Reports show "iPad" or "Christian's iPad" which is useless when managing 30+ devices. School IT can't organize reports by building, floor, classroom, or cart without manually cross-referencing device names.

**Who benefits:** Anyone managing multiple devices — school IT, enterprise mobility teams, clinical device coordinators, warehouse/logistics teams.

**Implementation:**

Add a persistent location tag per device:

```swift
// Models/DeviceInfo.swift — extend
struct DeviceInfo: Codable, Equatable {
    // Existing fields...
    let location: String?  // "Room 202", "Cart B", "Building A Floor 3"
}
```

Set location in the device name prompt (first launch) and in a settings screen:

```swift
// UserDefaults keys
"deviceLocation"  // persisted alongside "deviceName"
```

Include location in `peerInfo` message exchange:

```swift
// DiagnosticMessage.swift — extend peerInfo
case peerInfo(deviceName: String, osVersion: String, model: String,
              modelNumber: String, stableID: UUID, ssid: String?,
              bssid: String?, location: String?)
```

**Report impact:** Location appears in report headers, CSV exports, PDF analytics. Analytics can group by location: "Room 202 has 40% higher latency than Room 105."

**Files to modify:**
- `DeviceIdentifier.swift` — include location in `localDeviceInfo()`
- `DiagnosticMessage.swift` — add `location` to `peerInfo`
- `DeviceInfo.swift` — add `location` field (backward-compatible decoding)
- `DiagnosticMetrics.swift` — store peer location
- `ContentView.swift` — add location field to name prompt
- `TestReport.swift` / `ReportSummary.swift` — surface location
- `ReportAnalyticsView.swift` — group-by-location analytics
- CSV/PDF exports — include location column

---

## 7. Test Presets

**Problem:** Only two hardcoded configs exist: "Full Suite" (all 6 phases, full parameters) and "Quick Test" (reduced counts, skips heavy phases). Real-world users need different profiles for different scenarios — a network validation test is different from a stress test is different from a quick health check.

**Who benefits:** Everyone — customization is the difference between a diagnostic tool and a useful diagnostic tool.

**Implementation:**

```swift
// Models/TestPreset.swift
struct TestPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var description: String
    var config: TestSuiteConfig
    var isBuiltIn: Bool  // prevent deletion of system presets

    static let fullSuite = TestPreset(
        id: UUID(), name: "Full Suite",
        description: "All 6 phases with standard parameters",
        config: .default, isBuiltIn: true
    )
    static let quickCheck = TestPreset(
        id: UUID(), name: "Quick Check",
        description: "Reduced samples, skip heavy phases",
        config: .quick, isBuiltIn: true
    )
    static let stressTest = TestPreset(
        id: UUID(), name: "Stress Test",
        description: "Extended heavy load and packet loss phases",
        config: TestSuiteConfig(
            runLatencyBurst: false, runThroughput: false, runJitter: false,
            runPacketLoss: true, runLatencyUnderLoad: true, runHeavyLoad: true,
            packetLossCount: 1000, packetLossIntervalMs: 5
        ), isBuiltIn: true
    )
    static let latencyOnly = TestPreset(
        id: UUID(), name: "Latency Focus",
        description: "Latency burst + jitter only — fast validation",
        config: TestSuiteConfig(
            runLatencyBurst: true, runThroughput: false, runJitter: true,
            runPacketLoss: false, runLatencyUnderLoad: false, runHeavyLoad: false,
            latencyBurstCount: 200, jitterSampleCount: 200
        ), isBuiltIn: true
    )
}
```

Persist custom presets:

```swift
// Services/TestPresetStore.swift
class TestPresetStore {
    var presets: [TestPreset]  // built-in + user-created
    func save(_ preset: TestPreset)
    func delete(_ preset: TestPreset)  // only non-built-in
    func duplicate(_ preset: TestPreset) -> TestPreset
}
```

**UI:** Preset picker replaces the current phase toggle section in `TestSuiteView`. "Custom" option expands the full phase/parameter editor. Save button creates a named preset from current config.

**Files to modify:**
- New: `Models/TestPreset.swift`, `Services/TestPresetStore.swift`
- `TestSuiteView.swift` — preset picker, save/load UI
- `ConductorDashboardView.swift` — preset picker for queue config
- `TestSuiteConfig.swift` — add more static convenience configs

---

## 8. Network Impairment Simulation

**Problem:** You can measure how the connection performs *now*, but you can't simulate how it would perform under degraded conditions. When a user reports "the app is slow sometimes," you can't reproduce the conditions without physically degrading the network.

**Who benefits:** Developers testing app resilience, QA teams creating reproducible test conditions, network engineers validating failover behavior.

**Implementation:**

Add an impairment layer in the transport stack:

```swift
// Networking/ImpairmentTransport.swift
final class ImpairmentTransport: TransportProvider {
    let bridgeID = "impaired"
    let bridgeLabel: String  // "Native + 50ms delay"

    private let inner: TransportProvider
    private let config: ImpairmentConfig

    struct ImpairmentConfig {
        var addedLatencyMs: Double = 0       // fixed delay added to each send
        var jitterMs: Double = 0             // random ± jitter on top of delay
        var packetDropRate: Double = 0       // 0.0-1.0, probability of dropping a send
        var bandwidthLimitBps: Int?          // throttle throughput
        var burstLossLength: Int = 0         // consecutive drops (simulates interference bursts)
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        // Drop?
        if Double.random(in: 0...1) < config.packetDropRate {
            completion(nil)  // silently drop
            return
        }
        // Delay?
        let delay = config.addedLatencyMs + Double.random(in: -config.jitterMs...config.jitterMs)
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) {
                self.inner.send(data, completion: completion)
            }
        } else {
            inner.send(data, completion: completion)
        }
    }
}
```

This wraps any existing transport (native, bridge, etc.) — so you can test "Cordova + 100ms latency + 5% packet loss" to simulate a congested school Wi-Fi.

**UI:** Add an "Impairment" section in test config with sliders for latency, jitter, loss rate, and bandwidth. Show a warning badge when impairment is active.

**Files to modify:**
- New: `Networking/ImpairmentTransport.swift`, `Models/ImpairmentConfig.swift`
- `TransportProvider.swift` / `BridgeRegistry.swift` — wrap selected transport with impairment layer
- `TestSuiteView.swift` — impairment config UI
- `TestReport.swift` — record impairment config in report (critical: results are meaningless without knowing the conditions)

---

## 9. Peer Device Capability Negotiation — DONE

> **Implemented:** `agentCapabilities` carries `supportedBridges`, `appVersion` and `iosVersion`. `BonjourService` sends it as soon as the device enters agent mode, using `BridgeRegistry.enabledBridgeIDs`, the bundle short version and `UIDevice.systemVersion`. The conductor stores the list on the `DeviceConnection` and logs it with the version info.
>
> `validateBridgeSupport()` is now actually called: `executeRemoteRun` checks both devices before dispatching and, if either one did not advertise the bridge, logs which devices are missing it and fails the run immediately without retry — instead of dispatching anyway and failing later on an opaque 180s timeout. Native always validates. `FleetDeviceCard` shows a badge per advertised bridge.
>
> **Not done:** the conductor's bridge toggles are *not* dimmed by fleet capability. They dim only on local `BridgeRegistry` availability ("coming soon" for a bridge this build cannot run), so a bridge that some fleet device does not support can still be selected and queued, and there is no warning at pair-generation time — the incompatibility surfaces per run when the queue reaches it. The planned `supportedPhases` per-phase feature flags were never added.

**Problem:** `agentCapabilities` message exists and is sent when entering agent mode, but the conductor doesn't check it before dispatching tests. If an agent doesn't support a selected bridge transport, the test fails at runtime with an opaque error.

**Who benefits:** Anyone running mixed fleets — devices with different builds, different iOS versions, or different bridge support.

**Implementation:**

Conductor should validate before dispatching:

```swift
// ConductorService.swift — in executeRemoteRun
guard connA.supportedBridges.contains(run.bridgeTransport),
      connB.supportedBridges.contains(run.bridgeTransport) else {
    log("\(run.label): bridge \(run.bridgeTransport) not supported by both devices", level: .error)
    failedRuns.append(run)
    return
}
```

Extend capabilities with more metadata:

```swift
// DiagnosticMessage.swift — extend agentCapabilities
case agentCapabilities(
    supportedBridges: [String],
    appVersion: String,
    iosVersion: String,
    supportedPhases: [String]?  // future: per-phase feature flags
)
```

**UI:** Show capability badges on fleet device cards. Dim bridge toggles that aren't universally supported. Show a warning when generating pairs if some devices can't run the selected bridge.

**Files to modify:**
- `ConductorService.swift` — validate bridge support before dispatch
- `DiagnosticMessage.swift` — extend `agentCapabilities`
- `AgentService.swift` — send richer capabilities
- `FleetDeviceCard.swift` — show capability badges
- `ConductorDashboardView.swift` — bridge compatibility warnings

---

## 10. Latency Anomaly Detection — DONE

> **Implemented — live dashboard:** `checkForAnomaly()`, called from `appendLatency()`, flags a sample above mean + 3σ as a warning and above mean + 5σ as critical. The baseline is the previous 30 samples *excluding the candidate itself* — including it drags the mean toward the spike and inflates σ, which hides real anomalies on small windows. It needs at least 10 prior samples and a σ above 0.5ms before it will flag anything, and the stored `LatencyAnomaly` list is capped at 50. The dashboard latency chart overlays the anomalies that fall inside the visible window as yellow/red `PointMark`s (critical drawn larger), with a count badge underneath splitting critical from warning.
>
> **Implemented — report side:** `LatencyBurstResult.anomalyCount(in:)` counts burst samples above mean + 3σ. It returns nil below 10 samples — the field is then absent from the report rather than reported as a misleading zero — and returns 0 when σ is at or below 0.5ms, where the samples are too tight for a 3σ excursion to mean anything. `TestSuiteRunner` populates it for every latency burst (it was previously always nil), and `ReportDetailView` shows "N anomalies detected during burst" under the distribution card.
>
> **Not done:** tapping an anomaly does not open context (thermal state, CPU, phase at that timestamp), and the report stores only the count — the individual anomalies are not persisted.

**Problem:** The dashboard shows a latency chart but doesn't flag outliers. A single 200ms spike in a stream of 10ms samples is easy to miss visually but may indicate interference, thermal throttling, or a competing process.

**Who benefits:** Anyone monitoring connection quality in real time — especially during live testing sessions.

**Implementation:**

Add statistical anomaly detection to the metrics layer:

```swift
// DiagnosticMetrics.swift
struct LatencyAnomaly {
    let sampleIndex: Int
    let value: Double
    let mean: Double
    let threshold: Double  // value that triggered the flag
    let severity: AnomalySeverity
}
enum AnomalySeverity { case warning, critical }

var anomalies: [LatencyAnomaly] = []

func checkForAnomaly(_ sample: Double) {
    let recent = latencyHistory.suffix(30).map(\.value)
    guard recent.count >= 10 else { return }
    let mean = recent.reduce(0, +) / Double(recent.count)
    let stddev = sqrt(recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recent.count))

    if sample > mean + 3 * stddev {
        anomalies.append(LatencyAnomaly(
            sampleIndex: sampleCounter,
            value: sample,
            mean: mean,
            threshold: mean + 3 * stddev,
            severity: sample > mean + 5 * stddev ? .critical : .warning
        ))
    }
}
```

**UI:** Mark anomaly points on the latency chart with colored dots (yellow for warning, red for critical). Show an anomaly count badge on the Signal Quality card. Tapping an anomaly shows context (what was happening at that timestamp — thermal state, CPU, phase).

**Files to modify:**
- `DiagnosticMetrics.swift` — add anomaly detection in `appendLatency()`
- `DiagnosticDashboardView.swift` — overlay anomaly markers on latency chart, anomaly count badge
- `TestReport.swift` — include anomaly count and worst anomalies in report

---

## 11. Thermal Throttling Correlation — DONE

> **Implemented:** `SystemMonitor.ThermalTracker` records a `ThermalTransitionRecord` (timestamp, from, to) whenever the sampled thermal state differs from the last one it saw. `TestSuiteRunner` resets the tracker at the start of a run and samples it from `sampleSystem()`, which also feeds the CPU/memory/worst-thermal figures. Transitions ride along in `SystemMetricsResult.thermalTransitions` (nil when there were none, decoded with `decodeIfPresent`), and `ReportDetailView` draws each one as a dashed `RuleMark` on the latency chart coloured by the state entered, with a from→to legend below the chart.
>
> **Limits, stated plainly:** the correlation is coarse in two ways. Thermal state is polled only where `sampleSystem()` runs — after each phase, every 10 probes during heavy load, and every 50 chunks during latency-under-load — not continuously, so a brief excursion between sampling points is missed. And marker placement maps a transition's elapsed time proportionally across the whole run onto the latency-*burst* sample axis; the burst is only one phase near the start of the run, so a marker shows roughly when in the run the transition happened, not which latency sample it coincided with.

**Problem:** The system monitor captures thermal state and the test suite captures latency, but they're not correlated. Users see "thermal state = Serious" in the report and "p95 latency = 85ms" but can't tell if one caused the other.

**Who benefits:** QA teams diagnosing performance degradation, anyone running extended test sessions that cause device heating.

**Implementation:**

Track thermal state transitions with timestamps:

```swift
// SystemMonitor.swift
struct ThermalTransition {
    let timestamp: Date
    let from: ProcessInfo.ThermalState
    let to: ProcessInfo.ThermalState
}

// During test sampling, detect transitions:
if currentThermal != lastThermal {
    thermalTransitions.append(ThermalTransition(
        timestamp: Date(), from: lastThermal, to: currentThermal
    ))
    lastThermal = currentThermal
}
```

In the report, overlay thermal transitions on the latency timeline:

```swift
// TestReport.swift — extend SystemMetricsResult
struct SystemMetricsResult: Codable {
    // Existing...
    let thermalTransitions: [ThermalTransitionRecord]?  // timestamp + from/to
}
```

**UI:** In `ReportDetailView`, draw vertical lines on the latency chart at each thermal transition, color-coded by severity. This immediately shows whether latency spikes correlate with thermal events.

**Files to modify:**
- `SystemMonitor.swift` — track thermal transitions with timestamps
- `TestSuiteRunner.swift` — collect thermal transitions during test
- `TestReport.swift` — include in `SystemMetricsResult`
- `ReportDetailView.swift` — overlay thermal markers on latency chart

---

## 12. Scheduled Testing

**Problem:** Fleet health checks require someone to physically open the app, set up conductor mode, and run tests. Schools want overnight validation without manual intervention. Enterprise teams want daily regression baselines.

**Who benefits:** School IT, enterprise mobility teams, anyone managing deployed device fleets.

**Implementation:**

Use iOS `BGTaskScheduler` for background execution:

```swift
// Services/TestScheduleService.swift
class TestScheduleService {
    struct Schedule: Codable {
        var enabled: Bool
        var time: DateComponents  // hour + minute
        var daysOfWeek: Set<Int>  // 1=Sunday ... 7=Saturday
        var preset: UUID  // TestPreset ID
        var bridges: [String]
        var exportMethod: ExportMethod  // .none, .saveLocal, .airdrop
    }

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.ipadconnection.scheduledtest",
            using: nil
        ) { task in
            self.handleScheduledTest(task as! BGProcessingTask)
        }
    }

    func scheduleNext() {
        let request = BGProcessingTaskRequest(identifier: "com.ipadconnection.scheduledtest")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = nextScheduledDate()
        try? BGTaskScheduler.shared.submit(request)
    }
}
```

**Constraints:** iOS background tasks are best-effort — the system may delay or skip them. For reliable scheduling, the app should also support a "kiosk mode" where it stays in the foreground with the screen locked, running tests on a timer.

**UI:** Settings screen with schedule configuration: time picker, day-of-week toggles, preset selector, export method.

**Files to create:**
- `Services/TestScheduleService.swift`
- `Views/ScheduleSettingsView.swift`

**Files to modify:**
- `iPadDxApp.swift` — register background task on launch
- `Info.plist` — add `BGTaskSchedulerPermittedIdentifiers`

---

## 13. DNS / mDNS Resolution Timing — DONE

> **Implemented:** `DNSResolutionResult` (resolutionTimeMs, resolved, serviceName) in TestReport, optional `dnsResolution` on `TestSuiteResults` (decoded with `decodeIfPresent`). `.dnsResolution` added to the `TestPhase` enum with icon, short/detailed descriptions and rationale. `runDNSResolutionTest()` in TestSuiteRunner. Toggle in the TestSuiteView phase list (enabled in the default config, off in Quick). DNS result card in ReportDetailView with colour-coded timing and a slow-resolution warning. A phase that cannot resolve the name is marked `.failed("Could not resolve '<name>'")` and logs an error into the report.
>
> **What it actually measures — mDNS discovery only.** The phase starts a fresh `NWBrowser` for `_ipadconn._tcp` in `local.` and stops the clock the moment the peer's Bonjour service name appears in the browse results; a browser failure or a 10s timeout returns `resolved: false` with the elapsed time. It deliberately does **not** open an `NWConnection` and does **not** measure a TLS handshake: connecting to the peer's listener mid-suite would disturb the very connection under test. The earlier version of this section described an NWConnection + TLS handshake measurement; that is not what shipped, and the phase's in-app description says so too.

**Problem:** iPadDx connects using `NWEndpoint.service(name:type:domain:)` which handles mDNS resolution internally. Real apps resolve Bonjour names before connecting — and that resolution can add 100-500ms that iPadDx doesn't measure.

**Who benefits:** Developers building Bonjour apps, anyone diagnosing slow initial connections.

**Implementation:**

An optional phase that measures mDNS discovery time separately, without touching the live connection (this is what shipped):

```swift
// TestSuiteRunner.swift — measures browse-to-visible time, no TCP/TLS
private func runDNSResolutionTest(serviceName: String) async -> DNSResolutionResult {
    let start = CFAbsoluteTimeGetCurrent()

    let resolved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let browser = NWBrowser(for: .bonjour(type: "_ipadconn._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            // resume(true) as soon as `serviceName` appears in the results
        }
        browser.stateUpdateHandler = { state in
            // resume(false) on .failed
        }
        browser.start(queue: .global(qos: .userInitiated))
        // resume(false) after a 10s timeout
    }

    return DNSResolutionResult(
        resolutionTimeMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
        resolved: resolved,
        serviceName: serviceName
    )
}
```

**Files to modify:**
- `TestSuiteRunner.swift` — add DNS resolution phase
- `TestPhase.swift` — add `.dnsResolution` case
- `TestSuiteConfig.swift` — add `runDNSResolution` toggle
- `TestReport.swift` — add `DNSResolutionResult` to results

---

## 14. Report Trend Detection — DONE

> **Implemented:** `TrendAnalyzer.swift` fits a least-squares line over (date, value) samples with x normalised to days from the first sample, and reports direction from the slope, change as a percentage of the mean, and R² as confidence. It needs at least 3 samples and returns nil when the x-variance is zero (every report at the same instant, so no line can be fitted); a series where every value is identical is reported as `isFlat` with zero confidence rather than a spurious R² = 1 from a 0/0 division. Direction is `stable` unless the change exceeds 5% *and* R² is at least 0.1; otherwise `improving`/`degrading` according to each metric's `lowerIsBetter`. `describePeriod()` labels the window from the real sample dates ("12d span, 24 reports" / "same day, N reports") — never a placeholder.
>
> `analyzeAll()` covers avg latency, P95 latency, throughput, jitter and packet loss. `ReportAnalyticsView` renders a trend badge per metric with direction arrow, signed change %, a confidence bar and the period, plus a per-pair trend list; a pair with fewer than 3 reports is labelled as such rather than given an invented trend. `AnalyticsReportRenderer` draws the same trend table and a per-pair table (degrading pairs first) in the PDF.

**Problem:** Analytics show historical data but don't surface trends. Users must visually scan charts to notice "latency has been climbing over the past week" or "this device pair degraded after the iOS update."

**Who benefits:** IT teams tracking network health over time, anyone monitoring fleet performance.

**Implementation:**

Add trend computation to analytics:

```swift
// Services/TrendAnalyzer.swift
struct TrendResult {
    let metric: String  // "latency", "throughput", etc.
    let direction: TrendDirection  // .improving, .stable, .degrading
    let changePercent: Double  // % change over window
    let confidence: Double  // 0-1, based on sample count and R²
    let period: String  // "last 7 days", "last 30 reports"
}

enum TrendDirection { case improving, stable, degrading }

static func analyzeTrend(
    samples: [(date: Date, value: Double)],
    metric: String
) -> TrendResult {
    // Linear regression: slope indicates direction
    // R² indicates confidence
    // Normalize change as percentage of mean
}
```

**UI:** Add a "Trends" section to `ReportAnalyticsView` with trend badges per metric (green arrow up for improving, red arrow down for degrading). Per-pair trends show which pairs are getting worse.

**Files to create:**
- `Services/TrendAnalyzer.swift`

**Files to modify:**
- `ReportAnalyticsView.swift` — trend section with badges and mini charts
- `AnalyticsReportRenderer.swift` — trend summary in PDF export

---

## 15. Export Improvements — DONE

> **Implemented:** `ReportExporter.swift` with three formats — `ExportFormat.csv`, `.json`, `.pdf`, each carrying its own file extension and SF Symbol — plus `exportSingle`, `exportSingleJSON`, `exportBatch` and `clipboardSummary()`. JSON is a full-fidelity `TestReport` encoding, pretty-printed with sorted keys and ISO-8601 dates. Every string field in the CSV goes through `csvEscape` (always quoted, embedded quotes doubled), so a device name containing a comma or quote — or a raw fallback model identifier like `iPad16,3` — cannot break the row. Filenames carry a second-resolution timestamp plus a short random suffix so two exports of the same kind in the same second land on distinct files.
>
> `ReportListView` offers per-report CSV export, JSON export and Copy from the row menu, batch export of a selection in any format, and export-all in any format. `ReportDetailView` offers all three formats, a detailed per-report CSV, and clipboard copy. Generated files are handed to the system share sheet, which is what provides Files, AirDrop and the other destinations.
>
> **Not implemented:** there is no `xlsx` format and no `ExportDestination` enum — no webhook POST, and no in-app destination picker beyond the share sheet. The earlier version of this section listed both as shipped; they do not exist.

**Problem:** Reports can be exported as CSV or PDF one at a time. There's no batch export with metadata, no direct sharing to common destinations, and no machine-readable format for integration with other tools.

**Who benefits:** IT teams that feed data into dashboards, QA teams that need automated reporting, anyone who wants to share results quickly.

**Implementation:**

What shipped (formats only — destination is the system share sheet):

```swift
// Services/ReportExporter.swift
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, json, pdf
}

static func exportSingle(report: TestReport, format: ExportFormat) throws -> URL
static func exportBatch(reports: [TestReport], format: ExportFormat) throws -> [URL]
static func clipboardSummary(report: TestReport) -> String
```

The originally planned `xlsx` format and `ExportDestination` enum (`files` / `airdrop` / `clipboard` / `webhook`) were **not** built. Clipboard copy exists, but as `clipboardSummary()` written to `UIPasteboard` by the views, not as an export destination.

Add a JSON export format that preserves full report fidelity (unlike CSV which flattens):

```swift
func exportJSON(reports: [TestReport]) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(reports)
}
```

**Files to create:**
- `Services/ReportExporter.swift`

**Files to modify:**
- `ReportListView.swift` — batch selection + export format picker
- `ReportDetailView.swift` — share button with format options

---

## 16. Dark Mode Polish — DONE

> **Implemented:** `Helpers/AdaptiveColors.swift` centralises adaptation in one primitive, `Color.adaptive(_:scheme:)`: it resolves the base colour against a light trait collection and then increases saturation and reduces brightness so the hue still holds contrast against white. Every semantic helper is built on it — `gradeColor`, `latencyColor`, `bridgeColor`, `anomalyColor`, `thermalColor`, `trendColor`, `thresholdColor` (good/caution/bad, with `higherIsBetter`) and `statusColor`.
>
> `scheme` is optional and defaults to nil, which returns the base colour unchanged — so adding the parameter changed nothing on its own, and only call sites that read `\.colorScheme` and pass it get light-mode adaptation. `DiagnosticDashboardView`, `BridgeInfoView` and `FleetDeviceCard` pass it throughout; `ReportListView`, `ReportDetailView`, `TestSuiteView` and `ConductorDashboardView` pass it for grade colours.
>
> **Still not adaptive:** `ReportAnalyticsView` calls `trendColor` without a scheme, and `ReportDetailView` uses fixed colours for the histogram bars, latency line and stat items and calls `thermalColor` without a scheme. The PDF renderer is intentionally excluded: `AnalyticsReportRenderer` draws with a fixed light `PDFPalette` (white page, dark greys) rather than trait-dependent system colours, so a PDF exported in dark mode does not come out with light text on a white page.

**Problem:** Charts and some analytics views use hardcoded colors that look washed out or invisible in dark mode. Grade colors (green/blue/orange/red) need different saturation in dark vs. light mode.

**Who benefits:** Everyone who uses dark mode.

**Implementation:**

Audit all color usage and replace hardcoded values with adaptive colors:

```swift
// Helpers/AdaptiveColors.swift
extension Color {
    static func gradeColor(_ grade: String, scheme: ColorScheme) -> Color {
        switch grade {
        case "Excellent": scheme == .dark ? .green : .green.opacity(0.8)
        case "Good": scheme == .dark ? .blue : .blue.opacity(0.8)
        case "Fair": scheme == .dark ? .orange : .orange.opacity(0.8)
        case "Poor": scheme == .dark ? .red : .red.opacity(0.8)
        default: .gray
        }
    }
}
```

**Files to audit:**
- `ReportAnalyticsView.swift` — chart colors, background fills
- `ReportDetailView.swift` — grade badges, metric cards
- `DiagnosticDashboardView.swift` — latency chart colors
- `BridgeInfoView.swift` — overhead bar chart
- `FleetDeviceCard.swift` — status badges
- `AnalyticsReportRenderer.swift` — PDF rendering (always light mode, but verify)

---

## Priority Matrix

| Feature | Impact | Effort | Priority | Status |
|---|---|---|---|---|
| Test Cancellation | High | Low | **P0** | Done |
| Connection Drop Root Cause | High | Low | **P0** | Done |
| Auto-Retry Failed Pairs | High | Low | **P1** | Done |
| Device Location Tagging | High | Low | **P1** | Not started |
| Capability Negotiation | Medium | Low | **P1** | Done |
| Latency Anomaly Detection | Medium | Low | **P1** | Done |
| Dark Mode Polish | Medium | Low | **P1** | Done |
| Latency Distribution Histogram | High | Medium | **P2** | Done |
| Live Responder Metrics | High | Medium | **P2** | Done |
| Test Presets | High | Medium | **P2** | Not started |
| Thermal Throttling Correlation | Medium | Medium | **P2** | Done |
| Report Trend Detection | Medium | Medium | **P2** | Done |
| Export Improvements | Medium | Medium | **P2** | Done |
| DNS Resolution Timing | Medium | Medium | **P3** | Done |
| Network Impairment Simulation | High | High | **P3** | Not started |
| Scheduled Testing | High | High | **P3** | Not started |

Twelve rows are Done and four are Not started, matching the twelve DONE section markers above.

### What was implemented

**Models:** `DisconnectReason`, `DisconnectEvent`, `LatencyAnomaly`, `RemoteMetricsSample`, `HistogramBucket`, `ThermalTransitionRecord`, `DNSResolutionResult` — all with backward-compatible Codable decoding. Extended `LatencyBurstResult` with p5/p25/p75/p99 percentiles, histogram and anomaly count, and corrected its `median`/`percentile` maths. Extended `SystemMetricsResult` with thermal transitions. Extended `agentCapabilities` with app/iOS version. Added `liveMetrics` and `throughputAck` message types, and a real `payload: Data` on `throughputData`.

**Services:** `TrendAnalyzer.swift` (linear-regression trend detection), `ReportExporter.swift` (CSV/JSON/PDF single and batch export, escaped CSV, clipboard summary). Test cancellation in `TestSuiteRunner` with partial-report generation, and grading that scores only the dimensions that actually produced samples. Auto-retry in `ConductorService`, now called from the real failure paths. Bridge capability validation before remote dispatch. Live metrics broadcast in `DiagnosticEngine`. Thermal transition tracking in `SystemMonitor.ThermalTracker`. `ConnectionManager.onDisconnect` driving the disconnect history.

**Views:** Cancel button in TestSuiteView, and a standalone bridge section that states plainly that standalone runs are always native. Histogram chart + extended percentiles + burst anomaly count in ReportDetailView. Anomaly markers and count badge on the dashboard latency chart. Disconnect history with reasons in the dashboard health card. Live remote metrics on the peer info card. Trend badges and per-pair trends in ReportAnalyticsView. Capability badges on FleetDeviceCard. Retry badges and a results section that appears even when every run failed in ConductorDashboardView. `AdaptiveColors.swift` for scheme-aware grade/latency/bridge/thermal/anomaly/trend/threshold/status colours.

### Known gaps inside the shipped features

These are documented in the sections above; listed here so the DONE markers are not read as "nothing left":

- **1. Cancellation** — a cancelled conductor self-run is discarded rather than stored; standalone mode keeps the partial report in memory but offers no way to save it.
- **2. Disconnect root cause** — no `NWPath`-based detection; disconnect events are not carried into `TestReport`.
- **3. Histogram** — not aggregated across reports in analytics, not drawn in the PDF.
- **4. Auto-retry** — no user-facing toggle or retry-count control; retry limits are code constants.
- **5. Live responder metrics** — live samples are not persisted into the report or overlaid on its latency chart.
- **9. Capability negotiation** — bridge toggles are not dimmed by fleet capability, and there is no pair-generation warning; unsupported bridges fail per run.
- **10. Anomaly detection** — no tap-through context; reports store the count, not the anomalies.
- **11. Thermal correlation** — thermal state is polled at phase/loop sampling points, and markers are positioned proportionally over the run rather than per latency sample.
- **15. Export** — no xlsx, no `ExportDestination`, no webhook.
- **16. Dark mode** — ReportAnalyticsView and parts of ReportDetailView still use non-adaptive colours.

### What remains

| Feature | What's needed |
|---|---|
| **6. Device Location Tagging** | Add `location` field to DeviceInfo, persist in UserDefaults, include in peerInfo exchange, surface in reports and analytics |
| **7. Test Presets** | `TestPreset` model, `TestPresetStore` service, preset picker in TestSuiteView replacing phase toggles, save/load/duplicate UI |
| **8. Network Impairment Simulation** | `ImpairmentTransport` wrapping any transport, `ImpairmentConfig` model, sliders in test config UI, record conditions in report |
| **12. Scheduled Testing** | `TestScheduleService` with BGTaskScheduler, schedule config UI, background task registration, kiosk mode option |
