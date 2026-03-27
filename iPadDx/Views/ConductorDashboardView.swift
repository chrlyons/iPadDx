import SwiftUI

struct ConductorDashboardView: View {
    @Environment(BonjourService.self) private var service
    @Environment(ReportStore.self) private var reportStore
    @State private var showPairPicker = false
    @State private var pairDeviceA: PeerDevice?
    @State private var pairDeviceB: PeerDevice?

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
                    Text("\(conductor.connectedAgents.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let conductor, !conductor.fleet.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
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

                case let .running(index, total):
                    VStack(spacing: 8) {
                        ProgressView(value: Double(index), total: Double(total)) {
                            Text("Running pair \(index + 1) of \(total)")
                                .font(.caption)
                        }
                        .tint(.blue)
                        Text(conductor.currentPairLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        HStack(spacing: 12) {
            if let conductor {
                Button {
                    showPairPicker = true
                } label: {
                    Label("Add Pair", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(conductor.connectedAgents.count < 2 || conductor.queueStatus != .idle)

                Button {
                    let selfInfo = DeviceIdentifier.localDeviceInfo()
                    let selfPeer = PeerDevice(
                        id: DeviceIdentifier.stableID,
                        name: selfInfo.name,
                        endpoint: .hostPort(host: .ipv4(.loopback), port: 0)
                    )
                    selfPeer.chipFamily = DeviceIdentifier.chipFamily
                    conductor.generateAllPairs(includingSelf: selfPeer)
                } label: {
                    Label("All Pairs", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(conductor.connectedAgents.count < 2 || conductor.queueStatus != .idle)

                Button {
                    Task {
                        await conductor.runQueue(reportStore: reportStore)
                        // Save completed reports
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

    // MARK: - Results

    private var recentResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("Recent Results")
                    .font(.headline)
                Spacer()
            }

            if let conductor {
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
        // Include the conductor (this device) as a selectable option
        let selfInfo = DeviceIdentifier.localDeviceInfo()
        let selfPeer = PeerDevice(
            id: DeviceIdentifier.stableID,
            name: selfInfo.name + " (this device)",
            endpoint: .hostPort(host: .ipv4(.loopback), port: 0)
        )
        selfPeer.chipFamily = DeviceIdentifier.chipFamily
        selfPeer.model = selfInfo.model
        return [selfPeer] + agents.map(\.peer)
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
