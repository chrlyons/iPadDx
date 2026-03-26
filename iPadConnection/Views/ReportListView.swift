import SwiftUI

struct ReportListView: View {
    @Environment(ReportStore.self) private var store
    @State private var selectedForCompare: Set<UUID> = []
    @State private var compareMode = false
    @State private var showComparison = false
    @State private var exportItem: ExportItem?

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
                            Task.detached {
                                let url = await store.exportCSV(for: report)
                                await MainActor.run {
                                    if let url { exportItem = ExportItem(url: url) }
                                }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                    .overlay(alignment: .topTrailing) {
                        if compareMode {
                            Image(systemName: selectedForCompare
                                .contains(report.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedForCompare.contains(report.id) ? .blue : .secondary)
                                .padding(8)
                                .onTapGesture {
                                    toggleCompareSelection(report.id)
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved Reports")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.reports.count >= 2 {
                    Button(compareMode ? "Done" : "Compare") {
                        compareMode.toggle()
                        if !compareMode {
                            selectedForCompare.removeAll()
                        }
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if compareMode, selectedForCompare.count == 2 {
                    Button {
                        showComparison = true
                    } label: {
                        Label("Compare Selected", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(activityItems: [item.url])
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showComparison) {
            if let reports = getSelectedReports() {
                NavigationStack {
                    ReportComparisonView(reportA: reports.0, reportB: reports.1)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    showComparison = false
                                    compareMode = false
                                    selectedForCompare.removeAll()
                                }
                            }
                        }
                }
            }
        }
    }

    private func reportRow(_ report: TestReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.localDevice.chipFamily)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1), in: Capsule())
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(report.remoteDevice.chipFamily)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.1), in: Capsule())
                Spacer()
                Text(report.results.overallGrade)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(gradeColor(report.results.overallGrade))
            }

            Text("\(report.localDevice.name) \u{2194} \(report.remoteDevice.name)")
                .font(.subheadline)

            HStack {
                Text(report.date, style: .date)
                Text(report.date, style: .time)
                Spacer()
                Text(String(format: "%.1fs", report.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func toggleCompareSelection(_ id: UUID) {
        if selectedForCompare.contains(id) {
            selectedForCompare.remove(id)
        } else if selectedForCompare.count < 2 {
            selectedForCompare.insert(id)
        }
    }

    private func getSelectedReports() -> (TestReport, TestReport)? {
        let selected = store.reports.filter { selectedForCompare.contains($0.id) }
        guard selected.count == 2 else { return nil }
        return (selected[0], selected[1])
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
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
