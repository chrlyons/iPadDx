import SwiftUI

enum ActiveSheet: Identifiable {
    case export(urls: [URL])
    case compare(reportA: TestReport, reportB: TestReport)

    var id: String {
        switch self {
        case .export: "export"
        case .compare: "compare"
        }
    }
}

struct ReportListView: View {
    @Environment(ReportStore.self) private var store
    @State private var selectedReports: Set<UUID> = []
    @State private var selectionMode: SelectionMode = .none
    @State private var activeSheet: ActiveSheet?

    enum SelectionMode {
        case none
        case compare
        case export
    }

    var body: some View {
        List {
            if store.reports.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No saved reports yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Connect to a device and run the test suite to generate reports.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.reports) { report in
                    if selectionMode != .none {
                        Button {
                            toggleSelection(report.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedReports.contains(report.id)
                                    ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedReports.contains(report.id) ? .blue : .secondary)
                                reportRow(report)
                            }
                        }
                        .listRowBackground(
                            selectedReports.contains(report.id) ? Color.blue.opacity(0.08) : nil
                        )
                    } else {
                        NavigationLink(destination: ReportDetailView(report: report)) {
                            reportRow(report)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(report)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                exportSingle(report)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved Reports")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.reports.isEmpty {
                    Menu {
                        if selectionMode == .none {
                            Button {
                                selectionMode = .compare
                                selectedReports.removeAll()
                            } label: {
                                Label("Compare Two", systemImage: "arrow.left.arrow.right")
                            }
                            .disabled(store.reports.count < 2)

                            Button {
                                selectionMode = .export
                                selectedReports.removeAll()
                            } label: {
                                Label("Export Selected", systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button {
                                exportAll()
                            } label: {
                                Label("Export All (\(store.reports.count))", systemImage: "doc.on.doc")
                            }
                        } else {
                            Button("Done") {
                                exitSelectionMode()
                            }
                        }
                    } label: {
                        Image(systemName: selectionMode != .none ? "xmark.circle.fill" : "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode != .none {
                VStack(spacing: 8) {
                    Text(selectionModeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        if selectionMode == .compare, selectedReports.count == 2 {
                            Button {
                                if let pair = getSelectedReports() {
                                    activeSheet = .compare(reportA: pair.0, reportB: pair.1)
                                }
                            } label: {
                                Label("Compare", systemImage: "arrow.left.arrow.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        if selectionMode == .export, !selectedReports.isEmpty {
                            Button {
                                exportSelected()
                            } label: {
                                Label("Export (\(selectedReports.count))", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        Button {
                            exitSelectionMode()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case let .export(urls):
                ShareSheet(activityItems: urls)
                    .presentationDetents([.medium, .large])
            case let .compare(reportA, reportB):
                NavigationStack {
                    ReportComparisonView(reportA: reportA, reportB: reportB)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    activeSheet = nil
                                    exitSelectionMode()
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Row

    private func reportRow(_ report: TestReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.localDevice.chipFamily)
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.1), in: Capsule())
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(report.remoteDevice.chipFamily)
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.purple.opacity(0.1), in: Capsule())
                Spacer()
                Text(report.results.overallGrade)
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundStyle(gradeColor(report.results.overallGrade))
            }

            HStack {
                Text(report.localDevice.displayModel)
                Text("\u{2194}")
                Text(report.remoteDevice.displayModel)
            }
            .font(.caption)

            HStack {
                Text(report.date, style: .date)
                Text(report.date, style: .time)
                Spacer()
                Text(String(format: "%.1fs", report.durationSeconds))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Selection

    private var selectionModeLabel: String {
        switch selectionMode {
        case .none: ""
        case .compare: "Select 2 reports to compare (\(selectedReports.count)/2)"
        case .export: "Select reports to export (\(selectedReports.count) selected)"
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedReports.contains(id) {
            selectedReports.remove(id)
        } else {
            if selectionMode == .compare, selectedReports.count >= 2 { return }
            selectedReports.insert(id)
        }
    }

    private func exitSelectionMode() {
        selectionMode = .none
        selectedReports.removeAll()
    }

    private func getSelectedReports() -> (TestReport, TestReport)? {
        let selected = store.reports.filter { selectedReports.contains($0.id) }
        guard selected.count == 2 else { return nil }
        return (selected[0], selected[1])
    }

    // MARK: - Export

    private func exportSingle(_ report: TestReport) {
        Task {
            if let url = store.exportCSV(for: report) {
                activeSheet = .export(urls: [url])
            }
        }
    }

    private func exportSelected() {
        let selected = store.reports.filter { selectedReports.contains($0.id) }
        exportReports(selected)
    }

    private func exportAll() {
        exportReports(store.reports)
    }

    private func exportReports(_ reports: [TestReport]) {
        Task {
            var collectedURLs: [URL] = []
            for report in reports {
                if let url = store.exportCSV(for: report) {
                    collectedURLs.append(url)
                }
            }
            if reports.count > 1, let summaryURL = store.exportSummaryCSV(for: reports) {
                collectedURLs.insert(summaryURL, at: 0)
            }
            if !collectedURLs.isEmpty {
                activeSheet = .export(urls: collectedURLs)
            }
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

struct ExportItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
