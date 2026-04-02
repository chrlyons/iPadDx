# Bridge Transport — Architecture & Flow Diagrams

> **Status:** Implemented. These diagrams reflect the current codebase.

See [current_architecture.md](current_architecture.md) for the base architecture without bridges.

---

## Component Stack — With Bridges

```mermaid
graph TB
    subgraph "iPadDx App"
        TSR[TestSuiteRunner<br/>unchanged]
        CM[ConnectionManager<br/>delegates to TransportProvider]
        TP{TransportProvider<br/>Protocol}

        subgraph "Transport Implementations"
            NT[NativeTransport<br/>NWConnection direct]
            CT[CordovaTransport<br/>JSContext + exec/callback]
            RT[ReactNativeTransport<br/>JSContext + MessageQueue]
            FT[FlutterTransport<br/>MethodCodec + thread dispatch]
            CAP[CapacitorTransport<br/>WKWebView + postMessage]
        end

        BJ[BonjourService<br/>shared across transports]
    end

    TSR -->|"run phases"| CM
    CM -->|"send/receive"| TP
    TP --> NT
    TP --> CT
    TP --> RT
    TP --> FT
    TP --> CAP

    NT -->|direct| NW[NWConnection]
    CT -->|"Swift→JSCore→Swift"| NW
    RT -->|"Swift→JSCore→Swift"| NW
    FT -->|"Swift→Codec+Dispatch→Swift"| NW
    CAP -->|"Swift→WKWebView IPC→Swift"| NW

    BJ -->|"discovery shared"| NW
    NW <-->|"TLS-PSK over TCP"| WIFI((Local WiFi / AWDL))

    style TSR fill:#4a9eff,color:#fff
    style CM fill:#4a9eff,color:#fff
    style TP fill:#f5a623,color:#333
    style NT fill:#7ed321,color:#fff
    style CT fill:#e85d75,color:#fff
    style RT fill:#9b59b6,color:#fff
    style FT fill:#3498db,color:#fff
    style CAP fill:#2ecc71,color:#fff
    style NW fill:#2d6bc4,color:#fff
    style BJ fill:#2d6bc4,color:#fff
```

---

## Bridge Internal Data Paths

### Cordova (JSContext)

```
Send: Swift → base64 → JSContext exec() → command queue → JSON batch → parse → callback → base64 → Swift → NWConnection
Recv: NWConnection → Swift → base64 → JSContext event dispatch → JSON serialize/parse → callback → base64 → Swift
```

### React Native (JSContext)

```
Send: Swift → base64 → JSContext enqueueNativeCall → MessageQueue batch → JSON flush → parse → invokeCallback → base64 → Swift → NWConnection
Recv: NWConnection → Swift → base64 → JSContext event → MessageQueue → JSON flush → parse → callback → base64 → Swift
```

### Flutter (No Dart VM — see shortcuts in bridge_overhead.md)

```
Send: Swift → StandardMethodCodec encode → DispatchQueue hop (platform thread) → decode → encode result → DispatchQueue hop (main thread) → decode → Swift → NWConnection
Recv: NWConnection → Swift → StandardMethodCodec encode → DispatchQueue hop → decode → encode → DispatchQueue hop → decode → Swift
```

### Capacitor (WKWebView — real cross-process IPC)

```
Send: Swift → evaluateJavaScript("toNative(...)") → [WebKit IPC: App→WebContent] → JS serialize → postMessage → [WebKit IPC: WebContent→App] → Swift → NWConnection
Recv: NWConnection → Swift → evaluateJavaScript("triggerEvent(...)") → [WebKit IPC] → JS process → postMessage → [WebKit IPC] → Swift
```

---

## Native vs Cordova — Overhead Comparison

```mermaid
flowchart TB
    subgraph "Native Transport Path"
        direction LR
        NA[Swift send] --> NB[NWConnection] --> NC[TCP/TLS] --> ND[NWConnection] --> NE[Swift receive]
    end

    subgraph "Cordova Transport Path (both sides bridged)"
        direction LR
        CA[Swift send] --> CB[JSContext<br/>exec + queue] --> CC[JSON<br/>batch flush] --> CD[NWConnection] --> CE[TCP/TLS] --> CF[NWConnection] --> CG[JSContext<br/>event + callback] --> CH[Swift receive]
    end

    style NA fill:#7ed321,color:#fff
    style NB fill:#7ed321,color:#fff
    style NC fill:#7ed321,color:#fff
    style ND fill:#7ed321,color:#fff
    style NE fill:#7ed321,color:#fff

    style CA fill:#4a9eff,color:#fff
    style CB fill:#e85d75,color:#fff
    style CC fill:#e85d75,color:#fff
    style CD fill:#4a9eff,color:#fff
    style CE fill:#4a9eff,color:#fff
    style CF fill:#4a9eff,color:#fff
    style CG fill:#e85d75,color:#fff
    style CH fill:#4a9eff,color:#fff
```

---

## Updated Report Data Model

```mermaid
classDiagram
    class TestReport {
        +UUID id
        +Date date
        +DeviceInfo localDevice
        +DeviceInfo remoteDevice
        +TestSuiteResults results
        +TimeInterval durationSeconds
        +[String]? errors
        +[String]? skippedPhases
        +String? bridgeTransport
    }

    class ReportSummary {
        +UUID id
        +Date date
        +String overallGrade
        +String localChip
        +String remoteChip
        +Double latencyAvg
        +Double throughputBps
        +String bridgeTransport
        ~300 bytes per report
    }

    class ReportEntity {
        +UUID reportID
        +String bridgeTransport = "native"
        +Data? rawJSON
        +toSummary() ReportSummary
        +toTestReport() TestReport?
    }

    class ReportStore {
        +summaries: [ReportSummary]
        +loadFullReport(id) TestReport?
        +summaries(forBridge) [ReportSummary]
        +bridgeComparison() [BridgeComparisonRow]
    }

    ReportEntity ..> ReportSummary : toSummary()
    ReportEntity ..> TestReport : toTestReport()
    ReportStore --> ReportSummary : always in memory
    ReportStore --> TestReport : loaded on demand

    style TestReport fill:#f5a623,color:#333
    style ReportSummary fill:#7ed321,color:#fff
    style ReportEntity fill:#2d6bc4,color:#fff
    style ReportStore fill:#4a9eff,color:#fff
```

---

## Orchestration Protocol

```mermaid
flowchart LR
    subgraph "Conductor → Agent"
        M1[roleAssignment<br/>role: string]
        M2[orchestrateTest<br/>target, config, role<br/>bridgeTransport]
        M3[orchestrationCancel]
    end

    subgraph "Agent → Conductor"
        M4[agentCapabilities<br/>supportedBridges: string array]
        M5[orchestrationStatus<br/>phase, detail]
        M6[orchestrationReport<br/>reportJSON incl bridgeTransport]
    end

    style M1 fill:#4a9eff,color:#fff
    style M2 fill:#f5a623,color:#333
    style M3 fill:#4a9eff,color:#fff
    style M4 fill:#e85d75,color:#fff
    style M5 fill:#7ed321,color:#fff
    style M6 fill:#f5a623,color:#333
```

---

## Queue Interleaving

```mermaid
graph LR
    subgraph "3 Devices, 2 Bridges — 12 runs (interleaved)"
        R1["A→B native"] --> R2["A→C native"] --> R3["A→B cordova"] --> R4["B→C native"] --> R5["A→C cordova"] --> R6["B→A native"]
        R6 --> R7["B→C cordova"] --> R8["C→B native"] --> R9["B→A cordova"] --> R10["C→A native"] --> R11["C→B cordova"] --> R12["C→A cordova"]
    end

    style R1 fill:#7ed321,color:#fff
    style R2 fill:#7ed321,color:#fff
    style R4 fill:#7ed321,color:#fff
    style R6 fill:#7ed321,color:#fff
    style R8 fill:#7ed321,color:#fff
    style R10 fill:#7ed321,color:#fff
    style R3 fill:#e85d75,color:#fff
    style R5 fill:#e85d75,color:#fff
    style R7 fill:#e85d75,color:#fff
    style R9 fill:#e85d75,color:#fff
    style R11 fill:#e85d75,color:#fff
    style R12 fill:#e85d75,color:#fff
```
