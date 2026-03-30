import SwiftUI

struct ConsoleLogView: View {
    @State private var logStore = LogStore.shared
    @State private var filterText = ""
    @State private var filterLevel: LogEntry.LogLevel?
    @State private var autoScroll = true
    @State private var exportURL: URL?

    private var filteredEntries: [LogEntry] {
        logStore.entries.filter { entry in
            let matchesLevel = filterLevel == nil || entry.level == filterLevel
            let matchesText = filterText.isEmpty
                || entry.message.localizedCaseInsensitiveContains(filterText)
                || entry.category.localizedCaseInsensitiveContains(filterText)
            return matchesLevel && matchesText
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter logs...", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Picker("Level", selection: $filterLevel) {
                    Text("All").tag(LogEntry.LogLevel?.none)
                    Text("Debug").tag(LogEntry.LogLevel?.some(.debug))
                    Text("Info").tag(LogEntry.LogLevel?.some(.info))
                    Text("Warn").tag(LogEntry.LogLevel?.some(.warning))
                    Text("Error").tag(LogEntry.LogLevel?.some(.error))
                }
                .pickerStyle(.menu)
                .fixedSize()

                Text("\(filteredEntries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                List(filteredEntries) { entry in
                    logRow(entry)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .id(entry.id)
                }
                .listStyle(.plain)
                .font(.system(.caption2, design: .monospaced))
                .onChange(of: logStore.entries.count) {
                    if autoScroll, let last = filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Console")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $autoScroll) {
                    Image(systemName: autoScroll ? "arrow.down.to.line" : "arrow.down.to.line.compact")
                }
                .help("Auto-scroll")

                Button {
                    if let url = logStore.exportURL() {
                        exportURL = url
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    logStore.clear()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(LogStore.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(.secondary)
                .frame(width: 75, alignment: .leading)

            Text(entry.level.rawValue)
                .foregroundStyle(levelColor(entry.level))
                .fontWeight(.semibold)
                .frame(width: 40, alignment: .leading)

            Text(entry.category)
                .foregroundStyle(.blue)
                .frame(width: 55, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func levelColor(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .debug: .gray
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}
