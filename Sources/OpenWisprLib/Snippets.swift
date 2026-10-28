import Foundation

/// A saved note: say its name as the whole dictation and BrainDump pastes its text, word for word.
public struct Snippet: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// Snippets live in ~/.config/braindump/snippets.json. Never leaves the Mac.
public enum SnippetStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/braindump/snippets.json")
    }

    public static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    public static func save(_ snippets: [Snippet]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snippets) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The snippet whose name is the whole dictation. Case, punctuation and spacing don't matter
    /// ("YouTube script", "you tube script."), and a leading "paste" or "insert" is allowed.
    public static func match(_ spoken: String, in snippets: [Snippet] = load()) -> Snippet? {
        var said = key(spoken)
        for lead in ["paste", "insert", "snippet"] where said.hasPrefix(lead) && said.count > lead.count {
            said = String(said.dropFirst(lead.count))
            break
        }
        guard !said.isEmpty else { return nil }
        return snippets.first { !$0.text.isEmpty && key($0.name) == said }
    }

    /// Letters and digits only, lowercased.
    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
