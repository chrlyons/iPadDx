import SwiftUI

enum ActiveSheet: Identifiable {
    case export(urls: [URL])
    case compare(reportA: TestReport, reportB: TestReport)

    /// Identity has to vary with the payload — SwiftUI keeps a presented sheet whose
    /// id is unchanged, which would show the previous export's files.
    var id: String {
        switch self {
        case let .export(urls):
            "export-" + urls.map(\.lastPathComponent).joined(separator: "|")
        case let .compare(reportA, reportB):
            "compare-\(reportA.id.uuidString)-\(reportB.id.uuidString)"
        }
    }
}

struct ReportListView: View {
    @Environment(ReportStore.self) private var store
    @State private var selectedReports: Set<UUID> = []
    /// Selection in the order the user tapped, so comparison keeps A/B as picked.
    @State private var selectionOrder: [UUID] = []
    @State private var selectionMode: SelectionMode = .none
    @State private var activeSheet: ActiveSheet?
    @State private var exportFormat: ExportFormat = .csv
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showCopiedToast = false
    @State private var chipFilter: String = "All"
    @State private var gradeFilter: String = "All"
    @State private var osFilter: String = "All"
    @State private var bridgeFilter: String = "All"
    @State private var searchText: String = ""
    @Environment(\.colorScheme) private var colorScheme

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
        // "Not graded" is a real value a report can hold (a run that measured something
        // but nothing in a scored dimension). Listing only the four bands meant such
        // reports were visible but unfilterable. Ordered after the bands, and only
        // offered when some report actually has it.
        let ordered = SignalQuality.allCases.map(\.rawValue) + [TestSuiteResults.notGradedLabel]
        return ordered.filter { grades.contains($0) }
    }

    private var availableOSVersions: [String] {
        let versions = Set(store.summaries.flatMap { [$0.localOS, $0.remoteOS] })
        return versions.sorted()
    }

    private var filteredSummaries: [ReportSummary] {
        store.summaries.filter { s in
            if chipFilter != "All",
               s.localChip != chipFilter, s.remoteChip != chipFilter
            {
                return false
            }
            if gradeFilter != "All", s.overallGrade != gradeFilter {
                return false
            }
            if osFilter != "All",
               s.localOS != osFilter, s.remoteOS != osFilter
            {
                return false
            }
            if bridgeFilter != "All", s.bridgeTransport != bridgeFilter {
                return false
            }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let haystack = "\(s.localName) \(s.remoteName) \(s.localChip) \(s.remoteChip) \(s.localDisplayModel) \(s.remoteDisplayModel)"
                    .lowercased()
                if !haystack.contains(query) {
                    return false
                }
            }
            return true
        }
    }

    /// Selection clipped to what the current filters actually show. Filters can change
    /// after reports were picked, and no bulk action may ever touch a hidden report.
    private var visibleSelection: Set<UUID> {
        selectedReports.intersection(filteredSummaries.map(\.id))
    }

    var body: some View {
        List {
            if let initError = store.initError {
                storeUnavailableRow(initError)
            }

            if store.summaries.isEmpty {
                // Suppressed when the store failed to open — "no reports yet" would be a lie.
                if store.initError == nil {
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
                }
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
                            // Explicit format — a swipe must not silently inherit whatever
                            // was last picked in the toolbar menu.
                            Button {
                                exportSingle(summary.id, format: .csv)
                            } label: {
                                Label("Export CSV", systemImage: ExportFormat.csv.icon)
                            }
                            .tint(.blue)

                            Button {
                                exportSingle(summary.id, format: .json)
                            } label: {
                                Label("Export JSON", systemImage: ExportFormat.json.icon)
                            }
                            .tint(.teal)

                            Button {
                                copySummaryToClipboard(summary.id)
                            } label: {
                                Label("Copy", systemImage: "doc.on.clipboard")
                            }
                            .tint(.indigo)
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

                            Menu {
                                ForEach(ExportFormat.allCases) { format in
                                    Button {
                                        exportFormat = format
                                        selectionMode = .export
                                        selectedReports.removeAll()
                                    } label: {
                                        Label("Export as \(format.rawValue)", systemImage: format.icon)
                                    }
                                }
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

                            Menu {
                                ForEach(ExportFormat.allCases) { format in
                                    Button {
                                        exportFormat = format
                                        exportAll()
                                    } label: {
                                        Label("Export All as \(format.rawValue)", systemImage: format.icon)
                                    }
                                }

                                Divider()

                                Button {
                                    exportAnalyticsData()
                                } label: {
                                    Label("Analytics CSV (raw data)", systemImage: "chart.bar.doc.horizontal")
                                }
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
                        if selectionMode == .compare, visibleSelection.count == 2 {
                            Button {
                                compareSelected()
                            } label: {
                                Label("Compare", systemImage: "arrow.left.arrow.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        if selectionMode == .export, !visibleSelection.isEmpty {
                            Button {
                                exportSelected()
                            } label: {
                                Label("Export (\(visibleSelection.count))", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        if selectionMode == .delete, !visibleSelection.isEmpty {
                            Button(role: .destructive) {
                                deleteSelected()
                            } label: {
                                Label("Delete (\(visibleSelection.count))", systemImage: "trash")
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
                                Text(allVisibleSelected ? "Deselect All" : "Select All")
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
        .overlay {
            if isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing export…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(get: { exportError != nil }, set: {
                if !$0 {
                    exportError = nil
                }
            })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: showCopiedToast)
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

    // MARK: - Store Error

    private func storeUnavailableRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Saved reports are unavailable")
                    .font(.subheadline).fontWeight(.semibold)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                "Nothing was deleted — your saved reports are still on disk. Quit and relaunch iPadDx to try opening the database again. Reports finished in this session stay listed until you quit."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .listRowBackground(Color.orange.opacity(0.08))
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
        case .compare: "Select 2 reports to compare (\(visibleSelection.count)/2)"
        case .export: "Select reports to export (\(visibleSelection.count) selected)"
        case .delete: "Select reports to delete (\(visibleSelection.count) selected)"
        }
    }

    private var allVisibleSelected: Bool {
        !filteredSummaries.isEmpty && visibleSelection.count == filteredSummaries.count
    }

    private func toggleSelection(_ id: UUID) {
        if selectedReports.contains(id) {
            selectedReports.remove(id)
            selectionOrder.removeAll { $0 == id }
        } else {
            if selectionMode == .compare, visibleSelection.count >= 2 {
                return
            }
            selectedReports.insert(id)
            selectionOrder.append(id)
        }
    }

    private func exitSelectionMode() {
        selectionMode = .none
        selectedReports.removeAll()
        selectionOrder.removeAll()
    }

    private func compareSelected() {
        // A/B follow the order the user tapped, not SwiftData's fetch order.
        let visible = visibleSelection
        let ids = selectionOrder.filter { visible.contains($0) }
        guard ids.count == 2 else { return }
        let reports = store.loadFullReports(ids: Set(ids))
        guard let reportA = reports.first(where: { $0.id == ids[0] }),
              let reportB = reports.first(where: { $0.id == ids[1] })
        else { return }
        activeSheet = .compare(reportA: reportA, reportB: reportB)
    }

    private func selectAll() {
        let visible = filteredSummaries.map(\.id)
        let visibleSet = Set(visible)
        if allVisibleSelected {
            // Only clear what is on screen — hidden selections stay as they were.
            selectedReports.subtract(visibleSet)
            selectionOrder.removeAll { visibleSet.contains($0) }
        } else {
            for id in visible where !selectedReports.contains(id) {
                selectedReports.insert(id)
                selectionOrder.append(id)
            }
        }
    }

    private func deleteSelected() {
        // Strictly the visible set — a filtered-out report must never be deleted.
        for id in visibleSelection {
            store.delete(id)
        }
        exitSelectionMode()
    }

    // MARK: - Export

    private func exportSingle(_ id: UUID, format: ExportFormat) {
        guard let report = store.loadFullReport(id: id) else {
            exportError = "That report could not be loaded from the database, so it was not exported."
            return
        }
        runExport { try [ReportExporter.exportSingle(report: report, format: format)] }
    }

    private func exportSelected() {
        exportReports(store.loadFullReports(ids: visibleSelection))
    }

    private func exportAll() {
        exportReports(store.loadFullReports(ids: Set(filteredSummaries.map(\.id))))
    }

    private func exportReports(_ reports: [TestReport]) {
        guard !reports.isEmpty else {
            exportError = "There are no reports matching the current filters to export."
            return
        }
        let format = exportFormat
        runExport { try ReportExporter.exportBatch(reports: reports, format: format) }
    }

    /// Analytics/raw-data CSV for everything the current filters show.
    private func exportAnalyticsData() {
        let reports = store.loadFullReports(ids: Set(filteredSummaries.map(\.id)))
        guard !reports.isEmpty else {
            exportError = "There are no reports matching the current filters to export."
            return
        }
        let reportStore = store
        runExport {
            guard let url = reportStore.exportAnalyticsCSV(for: reports) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return [url]
        }
    }

    /// Builds export files off the main actor — PDF rendering and CSV assembly are
    /// O(reports) and freeze the UI on a large store — then presents the share sheet.
    private func runExport(_ build: @escaping @Sendable () throws -> [URL]) {
        isExporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
                do {
                    return try .success(build())
                } catch {
                    return .failure(error)
                }
            }.value
            isExporting = false
            switch result {
            case let .success(urls) where !urls.isEmpty:
                activeSheet = .export(urls: urls)
            case .success:
                exportError = "No files were produced."
            case let .failure(error):
                AppLog("Export failed: \(error)", level: .error, category: "Store")
                exportError = error.localizedDescription
            }
        }
    }

    private func copySummaryToClipboard(_ id: UUID) {
        if let report = store.loadFullReport(id: id) {
            UIPasteboard.general.string = ReportExporter.clipboardSummary(report: report)
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showCopiedToast = false
            }
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        Color.gradeColor(grade, scheme: colorScheme)
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
