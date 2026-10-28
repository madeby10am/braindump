import Foundation

/// Words dictated per day, for the "this week" line in the menu. Stored in
/// ~/.config/braindump/stats.json. Never leaves the Mac.
public enum UsageStats {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/braindump/stats.json")
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func load() -> [String: Int] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    public static func record(_ text: String, on date: Date = Date()) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return }
        var days = load()
        days[dayFormat.string(from: date), default: 0] += words
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(days).write(to: url, options: .atomic)
    }

    /// Words dictated over the last 7 days, today included.
    public static func wordsThisWeek(now: Date = Date()) -> Int {
        let days = load()
        return (0..<7).reduce(0) { total, back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
            return total + (days[dayFormat.string(from: day)] ?? 0)
        }
    }

    /// Typing runs about 40 words a minute and speaking about 150; the difference is time saved.
    public static func minutesSaved(words: Int) -> Int {
        Int((Double(words) / 40 - Double(words) / 150).rounded())
    }
}
