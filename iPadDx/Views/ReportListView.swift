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
    @State private var chipFilter: String = "All"
    @State private var gradeFilter: String = "All"
    @State private var osFilter: String = "All"
    @State private var bridgeFilter: String = "All"
    @State private var searchText: String = ""

    enum SelectionMode {
        case none
        case compare
        case export
        case delete
    }

    private var activeFilterCount: Int {
        [chipFilter, gradeFilter, osFilter, bridgeFilter].filter { $0 != "All" }.count
    }

    private var availableChips: [String] {
        let chips = Set(store.summaries.flatMap { [$0.localChip, $0.remoteChip] })
        return chips.sorted()
    }

    private var availableGrades: [String] {
        let grades = Set(store.summaries.map(\.overallGrade))
        return ["Excellent", "Good", "Fair", "Poor"].filter { grades.contains($0) }
    }

    private var availableOSVersions: [String] {
        let versions = Set(store.summaries.flatMap { [$0.localOS, $0.remoteOS] })
        return versions.sorted()
    }

    private var filteredSummaries: [ReportSummary] {
        store.summaries.filter { s in
            if chipFilter != "All",
               s.localChip != chipFilter, s.remoteChip != chipFilter
            { return false }
            if gradeFilter != "All", s.overallGrade != gradeFilter { return false }
            if osFilter != "All",
               s.localOS != osFilter, s.remoteOS != osFilter
            { return false }
            if bridgeFilter != "All", s.bridgeTransport != bridgeFilter { return false }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let haystack = "\(s.localName) \(s.remoteName) \(s.localChip) \(s.remoteChip) \(s.localDisplayModel) \(s.remoteDisplayModel)"
                    .lowercased()
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }

    var body: some View {
        List {
            if store.summaries.isEmpty {
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
                filterBar
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

                ForEach(filteredSummaries) { summary in
                    if selectionMode != .none {
                        Button {
                            toggleSelection(summary.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedReports.contains(summary.id)
                                    ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedReports.contains(summary.id) ? .blue : .secondary)
                                reportRow(summary)
                            }
                        }
                        .listRowBackground(
                            selectedReports.contains(summary.id) ? Color.blue.opacity(0.08) : nil
                        )
                    } else {
                        NavigationLink(destination: ReportDetailView(reportID: summary.id)) {
                            reportRow(summary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(summary.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                exportSingle(summary.id)
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
        .searchable(text: $searchText, prompt: "Search devices, chips, models…")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.summaries.isEmpty {
                    Menu {
                        if selectionMode == .none {
                            Button {
                                selectionMode = .compare
                                selectedReports.removeAll()
                            } label: {
                                Label("Compare Two", systemImage: "arrow.left.arrow.right")
                            }
                            .disabled(store.summaries.count < 2)

                            Button {
                                selectionMode = .export
                                selectedReports.removeAll()
                            } label: {
                                Label("Export Selected", systemImage: "square.and.arrow.up")
                            }

                            Button(role: .destructive) {
                                selectionMode = .delete
                                selectedReports.removeAll()
                            } label: {
                                Label("Delete Selected", systemImage: "trash")
                            }

                            Divider()

                            Button {
                                exportAll()
                            } label: {
                                Label("Export All (\(filteredSummaries.count))", systemImage: "doc.on.doc")
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
                                compareSelected()
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
                        if selectionMode == .delete, !selectedReports.isEmpty {
                            Button(role: .destructive) {
                                deleteSelected()
                            } label: {
                                Label("Delete (\(selectedReports.count))", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.large)
                        }
                        if selectionMode == .delete || selectionMode == .export {
                            Button {
                                selectAll()
                            } label: {
                                Text(selectedReports.count == filteredSummaries.count ? "Deselect All" : "Select All")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
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

    private func reportRow(_ summary: ReportSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.localChip)
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.1), in: Capsule())
                Image(systemName: "arrow.right")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(summary.remoteChip)
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.purple.opacity(0.1), in: Capsule())
                if summary.bridgeTransport != "native" {
                    Text(summary.bridgeTransport)
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(summary.overallGrade)
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundStyle(gradeColor(summary.overallGrade))
            }

            HStack(spacing: 4) {
                Text(summary.localDisplayModel)
                    .foregroundStyle(.primary)
                Text("(sender)")
                    .foregroundStyle(.tertiary)
                Text("\u{2192}")
                    .foregroundStyle(.secondary)
                Text(summary.remoteDisplayModel)
                    .foregroundStyle(.primary)
            }
            .font(.caption)

            HStack {
                Text(summary.date, style: .date)
                Text(summary.date, style: .time)
                Spacer()
                Text(String(format: "%.1fs", summary.durationSeconds))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterMenu("Chip", icon: "cpu", selection: $chipFilter, options: availableChips)
                    filterMenu("Grade", icon: "star", selection: $gradeFilter, options: availableGrades)
                    filterMenu("OS", icon: "ipad", selection: $osFilter, options: availableOSVersions)
                    if store.availableBridgeTransports().count > 1 {
                        filterMenu(
                            "Bridge",
                            icon: "network",
                            selection: $bridgeFilter,
                            options: store.availableBridgeTransports()
                        )
                    }
                    if activeFilterCount > 0 {
                        Button {
                            chipFilter = "All"
                            gradeFilter = "All"
                            osFilter = "All"
                            bridgeFilter = "All"
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.secondary)
                    }
                }
                .padding(.horizontal)
            }
            if activeFilterCount > 0 || !searchText.isEmpty {
                Text("\(filteredSummaries.count) of \(store.summaries.count) reports")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func filterMenu(
        _ label: String,
        icon: String,
        selection: Binding<String>,
        options: [String]
    ) -> some View {
        Menu {
            Button {
                selection.wrappedValue = "All"
            } label: {
                HStack {
                    Text("All \(label)s")
                    if selection.wrappedValue == "All" {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    HStack {
                        Text(option)
                        if selection.wrappedValue == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(selection.wrappedValue == "All" ? label : selection.wrappedValue)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selection.wrappedValue != "All"
                    ? AnyShapeStyle(.blue.opacity(0.12))
                    : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .foregroundStyle(selection.wrappedValue != "All" ? .blue : .primary)
        }
    }

    // MARK: - Selection

    private var selectionModeLabel: String {
        switch selectionMode {
        case .none: ""
        case .compare: "Select 2 reports to compare (\(selectedReports.count)/2)"
        case .export: "Select reports to export (\(selectedReports.count) selected)"
        case .delete: "Select reports to delete (\(selectedReports.count) selected)"
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

    private func compareSelected() {
        let ids = Array(selectedReports)
        guard ids.count == 2 else { return }
        let reports = store.loadFullReports(ids: selectedReports)
        guard reports.count == 2 else { return }
        activeSheet = .compare(reportA: reports[0], reportB: reports[1])
    }

    private func selectAll() {
        if selectedReports.count == filteredSummaries.count {
            selectedReports.removeAll()
        } else {
            selectedReports = Set(filteredSummaries.map(\.id))
        }
    }

    private func deleteSelected() {
        for id in selectedReports {
            store.delete(id)
        }
        exitSelectionMode()
    }

    // MARK: - Export

    private func exportSingle(_ id: UUID) {
        Task {
            if let report = store.loadFullReport(id: id),
               let url = store.exportCSV(for: report)
            {
                activeSheet = .export(urls: [url])
            }
        }
    }

    private func exportSelected() {
        let reports = store.loadFullReports(ids: selectedReports)
        exportReports(reports)
    }

    private func exportAll() {
        let ids = Set(filteredSummaries.map(\.id))
        let reports = store.loadFullReports(ids: ids)
        exportReports(reports)
    }

    private func exportReports(_ reports: [TestReport]) {
        Task.detached {
            var urls: [URL] = []
            if reports.count > 1, let summaryURL = await MainActor.run(body: { store.exportSummaryCSV(for: reports) }) {
                urls.append(summaryURL)
            } else if let report = reports.first,
                      let url = await MainActor.run(body: { store.exportCSV(for: report) })
            {
                urls.append(url)
            }
            await MainActor.run {
                if !urls.isEmpty {
                    activeSheet = .export(urls: urls)
                }
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
