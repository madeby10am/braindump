import Foundation

/// One dictation: what Whisper heard and what BrainDump pasted.
public struct DictationRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let raw: String
    public let output: String
    /// Style name when the AI formatter rewrote it; nil when pasted raw.
    public let style: String?
    public let model: String?
    public let seconds: Double?

    public var wasFormatted: Bool { style != nil }
}

/// Local-only log of recent dictations, kept at
/// ~/.config/braindump/history.json. Never leaves the Mac.
public enum History {
    public static let maxEntries = 50
    public static let didChange = Notification.Name("BrainDumpHistoryDidChange")

    private static let queue = DispatchQueue(label: "braindump.history")

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/braindump/history.json")
    }

    public static func load() -> [DictationRecord] {
        queue.sync { loadUnlocked() }
    }

    public static var last: DictationRecord? { load().first }

    public static func append(raw: String, output: String, style: String?, model: String?, seconds: Double?) {
        let record = DictationRecord(
            id: UUID(), date: Date(), raw: raw, output: output,
            style: style, model: model, seconds: seconds
        )
        queue.sync {
            var all = loadUnlocked()
            all.insert(record, at: 0)
            if all.count > maxEntries { all = Array(all.prefix(maxEntries)) }
            saveUnlocked(all)
        }
        notify()
    }

    public static func clear() {
        queue.sync { saveUnlocked([]) }
        notify()
    }

    private static func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static func loadUnlocked() -> [DictationRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DictationRecord].self, from: data)) ?? []
    }

    private static func saveUnlocked(_ records: [DictationRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
