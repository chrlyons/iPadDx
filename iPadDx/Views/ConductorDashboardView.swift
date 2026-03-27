import SwiftUI

struct ConductorDashboardView: View {
    @Environment(BonjourService.self) private var service
    @Environment(ReportStore.self) private var reportStore
    @State private var showPairPicker = false
    @State private var pairDeviceA: PeerDevice?
    @State private var pairDeviceB: PeerDevice?
    @State private var resultsExpanded = true
    @State private var eventLogExpanded = false

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

                // Completed reports
                if let conductor, !conductor.completedReports.isEmpty {
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
                            isTesting: conductor.queueStatus != .idle && conductor.queueStatus != .completed
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
                    Image(systemName: "ipad.badge.plus")
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
                    Text("\(conductor.testQueue.count) pairs")
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
                        ForEach(conductor.testQueue) { pair in
                            HStack {
                                Text(pair.label)
                                    .font(.caption)
                                Spacer()
                                Button {
                                    conductor.removePair(pair)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                case let .running(completed, total):
                    VStack(spacing: 8) {
                        ProgressView(value: Double(completed), total: Double(total)) {
                            Text("\(completed)/\(total) completed")
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
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("All tests completed")
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
                .disabled(conductor.queueStatus != .idle)

                HStack(spacing: 12) {
                    Button {
                        showPairPicker = true
                    } label: {
                        Label("Add Pair", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(conductor.queueStatus != .idle)

                    Button {
                        conductor.generateAllPairs()
                    } label: {
                        Label("All Pairs", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(conductor.connectedAgents.isEmpty || conductor.queueStatus != .idle)

                    Button {
                        Task {
                            await conductor.runQueue(reportStore: reportStore)
                            for report in conductor.completedReports {
                                reportStore.save(report, source: "conductor")
                            }
                        }
                    } label: {
                        Label("Run Queue", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(conductor.testQueue.isEmpty || conductor.queueStatus != .idle)
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
                let failedReports = conductor.completedReports
                    .filter { $0.results.overallGrade == "Poor" && $0.results.latencyBurst.sampleCount == 0 }

                if !failedReports.isEmpty, conductor.queueStatus == .idle || conductor.queueStatus == .completed {
                    Button {
                        rerunFailedTests(failedReports)
                    } label: {
                        Label("Re-run \(failedReports.count) Failed", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                ForEach(conductor.completedReports) { report in
                    NavigationLink(destination: ReportDetailView(report: report)) {
                        HStack {
                            Text("\(report.localDevice.chipFamily) \u{2192} \(report.remoteDevice.chipFamily)")
                                .font(.subheadline)
                            Spacer()
                            Text(report.results.overallGrade)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(gradeColor(report.results.overallGrade))
                            Text(String(format: "%.1fms avg", report.results.latencyBurst.avg))
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

    private func rerunFailedTests(_ failedReports: [TestReport]) {
        guard let conductor else { return }

        // Build lookup of all available devices (fleet + self)
        var allDevices: [PeerDevice] = conductor.connectedAgents.map(\.peer)
        if let sp = conductor.selfPeer {
            allDevices.insert(sp, at: 0)
        }

        for report in failedReports {
            // Match local device (the controller) — name should be reliable
            let deviceA = allDevices.first { peer in
                peer.name == report.localDevice.name
                    || (peer.chipFamily == report.localDevice.chipFamily
                        && peer.model == report.localDevice.model)
            }

            // Match remote device — might be "Unknown", so match by chip + model,
            // or fall back to any device with matching chip that isn't deviceA
            var deviceB: PeerDevice?
            if report.remoteDevice.name != "Unknown" {
                deviceB = allDevices.first { peer in
                    peer.id != deviceA?.id && peer.name == report.remoteDevice.name
                }
            }
            if deviceB == nil, report.remoteDevice.chipFamily != "Unknown" {
                deviceB = allDevices.first { peer in
                    peer.id != deviceA?.id && peer.chipFamily == report.remoteDevice.chipFamily
                }
            }

            if let a = deviceA, let b = deviceB {
                conductor.addPair(a, b)
            }
        }

        // Reset status so queue can run, then auto-start
        if !conductor.testQueue.isEmpty {
            conductor.queueStatus = .idle
            Task {
                await conductor.runQueue(reportStore: reportStore)
                for report in conductor.completedReports {
                    reportStore.save(report, source: "conductor")
                }
            }
        }
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
        switch grade {
        case "Excellent": .green
        case "Good": .blue
        case "Fair": .orange
        default: .red
        }
    }
}
