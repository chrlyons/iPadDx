import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    var formatted: String {
        let time = LogStore.timeFormatter.string(from: timestamp)
        return "[\(time)] [\(level.rawValue)] [\(category)] \(message)"
    }
}

@MainActor
@Observable
class LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 5000

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(_ message: String, level: LogEntry.LogLevel = .info, category: String = "App") {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        // Also print to stdout for Xcode console when attached
        #if DEBUG
            Swift.print(entry.formatted)
        #endif
    }

    func clear() {
        entries.removeAll()
    }

    func export() -> String {
        let header = "iPadDx Console Log — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))\n"
            + "Entries: \(entries.count)\n"
            + String(repeating: "—", count: 80) + "\n\n"
        return header + entries.map(\.formatted).joined(separator: "\n")
    }

    func exportURL() -> URL? {
        let text = export()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = "iPadDx_Console_\(dateFmt.string(from: Date())).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Global logging functions — use these instead of print()
func AppLog(_ message: String, category: String = "App") {
    Task { @MainActor in
        LogStore.shared.append(message, level: .info, category: category)
    }
}

func AppLog(_ message: String, level: LogEntry.LogLevel, category: String = "App") {
    Task { @MainActor in
        LogStore.shared.append(message, level: level, category: category)
    }
}
