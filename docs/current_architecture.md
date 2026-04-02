# iPadDx — Current Architecture & Flows

How iPadDx works today. Native Swift on Network.framework with pluggable bridge transports. See [bridge_overhead.md](bridge_overhead.md) for bridge transport details.

---

## Component Stack

```mermaid
graph TB
    subgraph "iPadDx App"
        TSR[TestSuiteRunner]
        CM[ConnectionManager<br/>delegates to TransportProvider]
        DE[DiagnosticEngine]
        NW[NWConnection<br/>Network.framework]
        BJ[BonjourService<br/>NWBrowser / NWListener]
        SM[SystemMonitor<br/>CPU, Memory, Battery, Thermal]
    end

    subgraph "Services"
        CS[ConductorService<br/>Fleet orchestration]
        AS[AgentService<br/>Remote test execution]
        RS[ReportStore<br/>SwiftData + ReportSummary]
    end

    TSR -->|"run phases"| CM
    CM -->|"via TransportProvider"| NW
    DE -->|"ping loop, peer info"| CM
    BJ -->|"discover / advertise"| NW
    SM -->|"system metrics"| TSR
    CS -->|"orchestrate"| DE
    AS -->|"execute remote tests"| TSR

    NW <-->|"TLS-PSK over TCP"| WIFI((Local WiFi / AWDL))
    TSR -->|"produce reports"| RS

    style TSR fill:#4a9eff,color:#fff
    style CM fill:#4a9eff,color:#fff
    style DE fill:#4a9eff,color:#fff
    style NW fill:#2d6bc4,color:#fff
    style BJ fill:#2d6bc4,color:#fff
    style SM fill:#9b59b6,color:#fff
    style CS fill:#f5a623,color:#333
    style AS fill:#f5a623,color:#333
    style RS fill:#7ed321,color:#fff
    style WIFI fill:#f0f0f0,color:#333
```

---

## Operating Modes

```mermaid
flowchart TD
    Launch([App Launch]) --> NamePrompt[Set device name]
    NamePrompt --> Mode{Select Mode}

    Mode -->|Standalone| SA[Connect to one peer<br/>via Bonjour discovery]
    Mode -->|Conductor| CO[Start fleet,<br/>agents join via Bonjour]
    Mode -->|Agent| AG[Join conductor's fleet<br/>via Bonjour discovery]

    SA --> SATest[Run 1:1 test suite<br/>directly between 2 iPads]
    CO --> COTest[Orchestrate test pairs<br/>across fleet of agents]
    AG --> AGTest[Wait for conductor commands<br/>execute assigned tests]

    SATest --> Report[TestReport saved]
    COTest --> Report
    AGTest --> Report

    style Launch fill:#4a9eff,color:#fff
    style SA fill:#7ed321,color:#fff
    style CO fill:#f5a623,color:#333
    style AG fill:#9b59b6,color:#fff
```

---

## Connection Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Discovered : Bonjour browser finds peer

    Discovered --> Connecting : User initiates / auto-connect
    Connecting --> Connected : NWConnection ready (TLS-PSK handshake complete)
    Connecting --> Failed : Timeout (15s) or TLS error

    Connected --> Connected : Keepalive (ping every 500ms)
    Connected --> Disconnected : Graceful disconnect message
    Connected --> Failed : Connection dropped / path change

    Failed --> Connecting : Retry
    Failed --> Disconnected : Give up

    Disconnected --> [*]
```

---

## Message Protocol

```mermaid
flowchart TB
    subgraph "Wire Format"
        direction LR
        LEN["4-byte length<br/>(big-endian UInt32)"] --> JSON["JSON payload<br/>(UTF-8 encoded)"]
    end

    subgraph "Message Categories"
        direction TB
        HB[Heartbeat<br/>ping / pong]
        PI[Peer Info<br/>device name, OS, model,<br/>chip, SSID, BSSID]
        TP[Throughput<br/>start / data / ack]
        TS[Test Suite<br/>testPing / testPong /<br/>testSuiteStatus]
        OR[Orchestration<br/>roleAssignment /<br/>orchestrateTest /<br/>orchestrationStatus /<br/>orchestrationReport /<br/>orchestrationCancel]
        SM[System Metrics<br/>responderMetrics]
        CT[Control<br/>disconnect / reportSync]
    end

    style LEN fill:#2d6bc4,color:#fff
    style JSON fill:#4a9eff,color:#fff
    style HB fill:#7ed321,color:#fff
    style OR fill:#f5a623,color:#333
```

---

## Standalone Test Flow

```mermaid
sequenceDiagram
    participant User
    participant UI as TestSuiteView
    participant Runner as TestSuiteRunner
    participant CM as ConnectionManager
    participant Net as NWConnection
    participant Remote as Remote iPad

    User->>UI: Tap "Run Test"
    UI->>Runner: runFullSuite()

    Note over Runner: Warm-up Phase (10 pings @ 100ms)
    loop 10 pings
        Runner->>CM: send(testPing)
        CM->>Net: send(data)
        Net->>Remote: TLS-PSK TCP
        Remote-->>Net: testPong
        Net-->>CM: receive(data)
        CM-->>Runner: pong received
    end

    Note over Runner: Phase 1 — Latency Burst (100 pings @ 50ms)
    loop 100 pings
        Runner->>CM: send(testPing)
        CM->>Net: send(data)
        Net->>Remote: TLS-PSK TCP
        Remote-->>Net: testPong
        Net-->>CM: receive(data)
        CM-->>Runner: record RTT
    end

    Note over Runner: Phase 2 — Sustained Throughput (10MB in 32KB chunks)
    Runner->>CM: send(throughputStart)
    loop 32KB chunks
        Runner->>CM: send(throughputData)
        CM->>Net: send(data)
        Net->>Remote: TLS-PSK TCP
    end
    Remote-->>Runner: throughputAck (bytes, duration)

    Note over Runner: Phase 3 — Jitter (150 pings @ 80ms)
    Note over Runner: Phase 4 — Packet Loss (500 pings @ 10ms)
    Note over Runner: Phase 5 — Latency Under Load (data + pings concurrent)
    Note over Runner: Phase 6 — Heavy Load (3 streams + pings for 15s)

    Runner->>Runner: computeGrade()
    Runner->>Runner: collect system metrics
    Note over Runner: Wait 2s for responderMetrics
    Runner-->>UI: TestReport
    UI-->>User: Show results + grade
```

---

## Conductor Fleet Flow

```mermaid
sequenceDiagram
    participant Cond as Conductor iPad
    participant CS as ConductorService
    participant AgentA as Agent iPad A
    participant AgentB as Agent iPad B
    participant AgentC as Agent iPad C

    Note over Cond,AgentC: Fleet Formation
    AgentA->>Cond: Bonjour discovery + connect
    Cond->>AgentA: roleAssignment("agent")
    AgentB->>Cond: Bonjour discovery + connect
    Cond->>AgentB: roleAssignment("agent")
    AgentC->>Cond: Bonjour discovery + connect
    Cond->>AgentC: roleAssignment("agent")

    Note over Cond: User taps "All Pairs" → 6 permutations (3x2)
    CS->>CS: generateAllPairs()

    Note over Cond,AgentC: Queue Execution — parallel where possible

    rect rgb(125, 211, 33, 0.1)
        Note over AgentA,AgentB: Pair 1: A → B (parallel with Pair 2)
        CS->>AgentB: orchestrateTest(target: A, role: "responder")
        CS->>AgentA: orchestrateTest(target: B, role: "controller")
        AgentA->>AgentB: test traffic
        AgentB-->>AgentA: responses
        AgentA->>Cond: orchestrationStatus("running", "Phase 1 — 45%")
    end

    rect rgb(155, 89, 182, 0.1)
        Note over AgentC,Cond: Pair 2: C → Conductor (parallel with Pair 1)
        Note over Cond: includeSelf = true
        CS->>AgentC: orchestrateTest(target: Cond, role: "controller")
        AgentC->>Cond: test traffic
        Cond-->>AgentC: responses
    end

    AgentA->>Cond: orchestrationReport(reportJSON)
    AgentA->>Cond: orchestrationStatus("completed")
    AgentC->>Cond: orchestrationReport(reportJSON)

    Note over CS: Mark pairs done, schedule next available
    Note over CS: Continue until queue empty
```

---

## Test Pair Generation

```mermaid
flowchart TD
    Fleet["Fleet: N devices<br/>(+ optional conductor)"] --> Gen{Generation method}

    Gen -->|"All Pairs"| AllPairs["N x (N-1) ordered permutations<br/>A→B and B→A are separate pairs"]
    Gen -->|"Manual"| Manual["Pick device A, pick device B<br/>adds one pair to queue"]

    AllPairs --> Queue[Test Queue]
    Manual --> Queue

    Queue --> Sched[Scheduler]
    Sched --> Check{Both devices idle?}
    Check -->|Yes| Launch[Launch pair test]
    Check -->|No| Wait[Wait for device to finish]
    Wait --> Sched

    Launch --> Complete[Report saved]
    Complete --> Sched
    Sched -->|Queue empty| Done[All tests complete]

    subgraph "Example: 3 devices"
        E1["A→B"]
        E2["A→C"]
        E3["B→A"]
        E4["B→C"]
        E5["C→A"]
        E6["C→B"]
    end

    style Fleet fill:#4a9eff,color:#fff
    style Done fill:#7ed321,color:#fff
```

---

## Report Data Model

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

    class DeviceInfo {
        +String name
        +String model
        +String modelNumber
        +String osVersion
        +String chipFamily
        +String displayModel
        +String shortDescription
        +String pairDescription
    }

    class TestSuiteResults {
        +LatencyBurstResult latencyBurst
        +ThroughputResult sustainedThroughput
        +JitterResult jitterMeasurement
        +PacketLossResult packetLossStress
        +LatencyUnderLoadResult latencyUnderLoad
        +SystemMetricsResult systemMetrics
        +String overallGrade
        +ResponderMetricsResult? responderMetrics
    }

    class LatencyBurstResult {
        +Double min / max / avg / median / p95
        +Int sampleCount
        +[Double] samples
    }

    class ThroughputResult {
        +Double bytesPerSecond
        +Int totalBytes
        +Double durationSeconds
    }

    class JitterResult {
        +Double averageJitter / maxJitter
        +Int sampleCount
    }

    class PacketLossResult {
        +Int sent / received
        +Double lostPercent
        +Double durationSeconds
    }

    class LatencyUnderLoadResult {
        +Double baselineAvg / underLoadAvg
        +Double degradationPercent
        +Int sampleCount
    }

    class SystemMetricsResult {
        +Float batteryStart / batteryEnd
        +Double batteryDrainPercent
        +Double peakCpuUsage / avgCpuUsage
        +Double peakMemoryMB
        +String thermalStateDuringTest
    }

    TestReport --> DeviceInfo : localDevice
    TestReport --> DeviceInfo : remoteDevice
    TestReport --> TestSuiteResults : results
    TestSuiteResults --> LatencyBurstResult
    TestSuiteResults --> ThroughputResult
    TestSuiteResults --> JitterResult
    TestSuiteResults --> PacketLossResult
    TestSuiteResults --> LatencyUnderLoadResult
    TestSuiteResults --> SystemMetricsResult
```

---

## Report Lifecycle

```mermaid
flowchart LR
    subgraph "Test Execution"
        TSR[TestSuiteRunner] -->|produces| TR[TestReport]
    end

    subgraph "Persistence"
        TR -->|save| RS[ReportStore]
        RS -->|SwiftData| RE[ReportEntity]
        RE -->|load| RS
        RS -->|query| QR[Query Results]
    end

    subgraph "Queries"
        QR -.->|by chip pair| F1["reports(forChipPair:)"]
        QR -.->|by source| F2["reports(fromSource:)"]
        QR -.->|avg latency| F3["averageLatency(forChip:)"]
    end

    subgraph "Export"
        QR -->|single| CSV1[Report CSV]
        QR -->|batch| CSV2[Summary CSV]
        QR -->|analysis| CSV3[Analytics CSV]
        QR -->|render| PDF[PDF Report]
    end

    style TSR fill:#4a9eff,color:#fff
    style TR fill:#f5a623,color:#333
    style RS fill:#7ed321,color:#fff
    style RE fill:#7ed321,color:#fff
```

---

## Grading Algorithm

```mermaid
flowchart TD
    Results[Test Suite Results] --> Score[Calculate Score]

    Score --> Lat{Avg Latency}
    Lat -->|"< 10ms"| L3[+3]
    Lat -->|"< 30ms"| L2[+2]
    Lat -->|"< 100ms"| L1[+1]
    Lat -->|">= 100ms"| L0[+0]

    Score --> Jit{Avg Jitter}
    Jit -->|"< 5ms"| J3[+3]
    Jit -->|"< 15ms"| J2[+2]
    Jit -->|"< 30ms"| J1[+1]
    Jit -->|">= 30ms"| J0[+0]

    Score --> PL{Packet Loss}
    PL -->|"< 1%"| P3[+3]
    PL -->|"< 5%"| P2[+2]
    PL -->|"< 10%"| P1[+1]
    PL -->|">= 10%"| P0[+0]

    Score --> Deg{Load Degradation}
    Deg -->|"<= 0%"| D3[+3]
    Deg -->|"< 50%"| D2[+2]
    Deg -->|"< 100%"| D1[+1]
    Deg -->|">= 100%"| D0[+0]

    L3 & L2 & L1 & L0 --> Total[Sum: 0-12 points]
    J3 & J2 & J1 & J0 --> Total
    P3 & P2 & P1 & P0 --> Total
    D3 & D2 & D1 & D0 --> Total

    Total --> Grade{Grade}
    Grade -->|"9-12"| Excellent[Excellent]
    Grade -->|"6-8"| Good[Good]
    Grade -->|"3-5"| Fair[Fair]
    Grade -->|"0-2"| Poor[Poor]

    style Excellent fill:#7ed321,color:#fff
    style Good fill:#4a9eff,color:#fff
    style Fair fill:#f5a623,color:#333
    style Poor fill:#e85d75,color:#fff
```

---

## Orchestration Protocol Messages

```mermaid
flowchart LR
    subgraph "Conductor → Agent"
        M1[roleAssignment<br/>role: string]
        M2[orchestrateTest<br/>targetDeviceName<br/>configJSON<br/>role: controller/responder<br/>bridgeTransport]
        M3[orchestrationCancel]
    end

    subgraph "Agent → Conductor"
        M4[agentCapabilities<br/>supportedBridges: string array]
        M5[orchestrationStatus<br/>phase: preparing/connecting/<br/>running/completed/failed<br/>detail: progress string]
        M6[orchestrationReport<br/>reportJSON: full TestReport]
    end

    subgraph "Peer ↔ Peer (during test)"
        M6[testPing / testPong]
        M7[throughputStart / Data / Ack]
        M8[peerInfo exchange]
        M9[responderMetrics]
    end

    style M1 fill:#4a9eff,color:#fff
    style M2 fill:#4a9eff,color:#fff
    style M3 fill:#4a9eff,color:#fff
    style M4 fill:#7ed321,color:#fff
    style M5 fill:#7ed321,color:#fff
    style M6 fill:#9b59b6,color:#fff
    style M7 fill:#9b59b6,color:#fff
    style M8 fill:#9b59b6,color:#fff
    style M9 fill:#9b59b6,color:#fff
```
