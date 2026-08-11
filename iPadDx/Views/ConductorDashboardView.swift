import SwiftUI

struct ConductorDashboardView: View {
    @Environment(BonjourService.self) private var service
    @Environment(ReportStore.self) private var reportStore
    @State private var showPairPicker = false
    @State private var pairDeviceA: PeerDevice?
    @State private var pairDeviceB: PeerDevice?
    @State private var resultsExpanded = true
    @State private var eventLogExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var conductor: ConductorService? {
        service.conductorService
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Fleet status
                fleetSection

                // Test queue
                queueSection

                // Queue controls
                controlsSection

                // Results — shown whenever there is anything to report. Gating this on
                // completedReports alone hid the failed-run list and the Re-run Failed
                // button in exactly the case they exist for: a queue where everything failed.
                if let conductor, !conductor.completedReports.isEmpty || !conductor.failedRuns.isEmpty {
                    recentResultsSection
                }

                // Event log
                if let conductor, !conductor.eventLog.isEmpty {
                    eventLogSection
                }
            }
            .padding()
        }
        .navigationTitle("Conductor")
        .sheet(isPresented: $showPairPicker) {
            pairPickerSheet
        }
    }

    // MARK: - Fleet

    private var fleetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Fleet")
                    .font(.headline)
                Spacer()
                if let conductor {
                    let selfCount = conductor.includeSelf ? 1 : 0
                    Text("\(conductor.connectedAgents.count + selfCount) devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let conductor, !conductor.fleet.isEmpty || conductor.includeSelf {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    // Self device card
                    if conductor.includeSelf {
                        SelfDeviceCard(
                            info: DeviceIdentifier.localDeviceInfo(),
                            isTesting: conductor.isQueueRunning && conductor.selfIsTesting
                        )
                    }

                    ForEach(conductor.fleet) { connection in
                        FleetDeviceCard(connection: connection) {
                            conductor.disconnectDevice(connection)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No agents connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Tap a discovered device in the sidebar to add it to the fleet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.number")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Test Queue")
                    .font(.headline)
                Spacer()
                if let conductor {
                    Text("\(conductor.testQueue.count) runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let conductor {
                switch conductor.queueStatus {
                case .idle:
                    if conductor.testQueue.isEmpty {
                        Text("No tests queued. Add pairs or use 'Test All Pairs'.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(conductor.testQueue) { run in
                            HStack {
                                Text(run.label)
                                    .font(.caption)
                                Spacer()
                                if run.bridgeTransport != "native" {
                                    Text(run.bridgeTransport)
                                        .font(.caption2)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(.orange.opacity(0.15), in: Capsule())
                                }
                                Button {
                                    conductor.removeRun(run)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                case let .running(finished, total):
                    VStack(spacing: 8) {
                        ProgressView(value: Double(finished), total: Double(total)) {
                            // "finished" covers failed and skipped runs too, so don't
                            // label the progress figure as completed.
                            Text("\(finished)/\(total) finished")
                                .font(.caption)
                        }
                        .tint(.blue)
                        if !conductor.runningPairs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Running now:")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ForEach(conductor.runningPairs, id: \.self) { label in
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.6)
                                        Text(label).font(.caption)
                                    }
                                }
                            }
                        }
                    }

                case .completed:
                    HStack {
                        let clean = conductor.failedCount == 0 && conductor.skippedCount == 0
                        Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(clean ? .green : .orange)
                        // Never claim "all completed" when runs failed or were skipped.
                        Text(clean ? "All tests completed" : conductor.lastQueueBreakdown)
                            .font(.subheadline)
                        Spacer()
                    }

                case let .failed(error):
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 12) {
            if let conductor {
                // Include self toggle
                Toggle(isOn: Binding(
                    get: { conductor.includeSelf },
                    set: { conductor.includeSelf = $0 }
                )) {
                    HStack {
                        Image(systemName: "ipad")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text("Include This Device")
                                .font(.subheadline)
                            Text(DeviceIdentifier.localDeviceInfo().name + " (" + DeviceIdentifier.chipFamily + ")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .disabled(conductor.isQueueRunning)

                // Bridge transport toggles
                bridgeTransportSection(conductor)

                HStack(spacing: 12) {
                    Button {
                        showPairPicker = true
                    } label: {
                        Label("Add Pair", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(conductor.isQueueRunning)

                    Button {
                        conductor.generateAllPairs()
                    } label: {
                        Label("All Pairs", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(conductor.connectedAgents.isEmpty || conductor.isQueueRunning)

                    if conductor.isQueueRunning {
                        Button(role: .destructive) {
                            conductor.cancelQueue()
                        } label: {
                            Label("Cancel", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button {
                            Task {
                                await conductor.runQueue()
                                for report in conductor.completedReports {
                                    reportStore.save(report, source: "conductor")
                                }
                            }
                        } label: {
                            Label("Run Queue", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(conductor.testQueue.isEmpty || conductor.isQueueRunning)
                    }
                }
            }
        }
    }

    // MARK: - Results (collapsible)

    private var recentResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    resultsExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("Recent Results")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let conductor {
                        Text("(\(conductor.completedReports.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(resultsExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if resultsExpanded, let conductor {
                if !conductor.failedRuns.isEmpty,
                   !conductor.isQueueRunning
                {
                    VStack(spacing: 4) {
                        ForEach(conductor.failedRuns) { run in
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                Text(run.label)
                                    .font(.caption)
                                let retries = conductor.retryCount[run.id, default: 0]
                                if retries > 0 {
                                    Text("\(retries)/\(conductor.maxRetries) retries")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.red.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                            }
                        }
                    }

                    Button {
                        rerunFailedRuns()
                    } label: {
                        Label("Re-run \(conductor.failedRuns.count) Failed", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                ForEach(conductor.completedReports) { report in
                    NavigationLink(destination: ReportDetailView(report: report)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(report.localDevice.chipFamily) \u{2192} \(report.remoteDevice.chipFamily)")
                                    .font(.subheadline)
                                if let bridge = report.bridgeTransport, bridge != "native" {
                                    Text(bridge)
                                        .font(.caption2)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(.orange.opacity(0.15), in: Capsule())
                                }
                            }
                            Spacer()
                            Text(report.results.overallGrade)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(gradeColor(report.results.overallGrade))
                            Text(report.results.measuredLatencyAvg
                                .map { String(format: "%.1fms avg", $0) } ?? "no latency measured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Pair Picker

    private var pairPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let conductor {
                    let agents = conductor.connectedAgents

                    Text("Select two devices to test (including this device)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    let allDevices = allSelectableDevices(agents)

                    Picker("Device A", selection: $pairDeviceA) {
                        Text("Select...").tag(nil as PeerDevice?)
                        ForEach(allDevices, id: \.id) { device in
                            Text("\(device.name) (\(device.chipFamily ?? "?"))").tag(device as PeerDevice?)
                        }
                    }

                    Picker("Device B", selection: $pairDeviceB) {
                        Text("Select...").tag(nil as PeerDevice?)
                        ForEach(allDevices, id: \.id) { device in
                            if device.id != pairDeviceA?.id {
                                Text("\(device.name) (\(device.chipFamily ?? "?"))").tag(device as PeerDevice?)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Add Test Pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showPairPicker = false
                        pairDeviceA = nil
                        pairDeviceB = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let a = pairDeviceA, let b = pairDeviceB {
                            conductor?.addPair(a, b)
                        }
                        showPairPicker = false
                        pairDeviceA = nil
                        pairDeviceB = nil
                    }
                    .disabled(pairDeviceA == nil || pairDeviceB == nil)
                }
            }
        }
    }

    private func allSelectableDevices(_ agents: [DeviceConnection]) -> [PeerDevice] {
        var devices = agents.map(\.peer)
        if let sp = conductor?.selfPeer {
            devices.insert(sp, at: 0)
        }
        return devices
    }

    // MARK: - Event Log (collapsible)

    private var eventLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    eventLogExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title2)
                        .foregroundStyle(.gray)
                    Text("Event Log")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let conductor {
                        Text("(\(conductor.eventLog.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let conductor, eventLogExpanded {
                        Button("Clear") {
                            conductor.eventLog.removeAll()
                        }
                        .font(.caption)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(eventLogExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if eventLogExpanded, let conductor {
                ForEach(conductor.eventLog) { event in
                    HStack(spacing: 8) {
                        Image(systemName: eventIcon(event.level))
                            .font(.caption2)
                            .foregroundStyle(eventColor(event.level))
                            .frame(width: 14)
                        Text(event.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 65, alignment: .leading)
                        Text(event.message)
                            .font(.caption)
                            .foregroundStyle(event.level == .error ? .red : .primary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Re-run Failed

    private func rerunFailedRuns() {
        guard let conductor else { return }

        // Re-queue the exact runs that failed — preserves bridge transport
        for run in conductor.failedRuns {
            conductor.testQueue.append(TestRun(pair: run.pair, bridgeTransport: run.bridgeTransport))
        }
        conductor.failedRuns.removeAll()

        guard !conductor.testQueue.isEmpty else { return }
        let alreadySaved = Set(conductor.completedReports.map(\.id))
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Keep the results already on screen — a retry should add to them, not wipe them.
            await conductor.runQueue(preservingResults: true)
            for report in conductor.completedReports where !alreadySaved.contains(report.id) {
                reportStore.save(report, source: "conductor")
            }
        }
    }

    private func bridgeTransportSection(_ conductor: ConductorService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.teal)
                Text("Bridge Transports")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(conductor.selectedBridges.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(BridgeRegistry.available) { bridge in
                HStack {
                    Image(systemName: conductor.selectedBridges.contains(bridge.id)
                        ? "checkmark.square.fill" : "square")
                        .foregroundStyle(bridge.enabled ? .blue : .gray)
                    Text(bridge.label)
                        .font(.caption)
                    if bridge.id == "native" {
                        Text("always on")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !bridge.enabled, bridge.id != "native" {
                        Spacer()
                        Text("coming soon")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .onTapGesture {
                    guard bridge.enabled, bridge.id != "native" else { return }
                    if conductor.selectedBridges.contains(bridge.id) {
                        conductor.selectedBridges.removeAll { $0 == bridge.id }
                    } else {
                        conductor.selectedBridges.append(bridge.id)
                    }
                }
                .opacity(bridge.enabled ? 1 : 0.5)
            }
        }
        .padding(.horizontal)
        .disabled(conductor.isQueueRunning)
    }

    // MARK: - Helpers

    private func eventIcon(_ level: ConductorEvent.EventLevel) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.circle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private func eventColor(_ level: ConductorEvent.EventLevel) -> Color {
        switch level {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        Color.gradeColor(grade, scheme: colorScheme)
    }
}
