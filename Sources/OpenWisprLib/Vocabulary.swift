import Foundation

/// Spelling and casing for technical terms. Speech models write "github",
/// "word press" or "quad code"; this puts them right. The built-in list covers
/// common developer and tool names, and `Config.vocabulary` adds the user's own
/// (company names, product names, people). The same words also go to Whisper
/// as a hint so it hears them correctly in the first place.
public enum Vocabulary {
    /// Terms whose casing is unambiguous. Matched case-insensitively as whole words.
    public static let builtIn: [String] = [
        // The first 24 are also handed to Whisper as a spelling hint, so the most-dictated terms come first.
        "GitHub", "VS Code", "Claude Code", "Claude", "WordPress", "WooCommerce", "n8n", "JavaScript", "TypeScript",
        "Python", "JSON", "API", "npm", "Docker", "PostgreSQL", "Supabase", "Vercel", "ChatGPT", "OpenAI", "Anthropic",
        "HTML", "CSS", "PHP", "SQL",
        "GitLab", "APIs", "URL", "URLs", "CLI", "SSH", "AWS", "Kubernetes", "MySQL", "Next.js", "Node.js", "Xcode",
        "SwiftUI", "macOS", "iOS", "iPhone", "iPad", "LinkedIn", "YouTube", "WhatsApp", "SSD", "USB", "Wi-Fi",
    ]

    /// Common mis-hearings and split spellings. Pattern (case-insensitive, whole words) -> replacement.
    private static let aliases: [(pattern: String, replacement: String)] = [
        ("(?:vs|v s|versus|visual studio|vee ess) code|vscode", "VS Code"),
        ("(?:quad|clod|claud|cloud|clawed|claude) code", "Claude Code"),
        ("(?:git|jit) hub", "GitHub"),
        ("appie|appy", "API"),
        ("word press", "WordPress"),
        ("woo commerce", "WooCommerce"),
        ("java script", "JavaScript"),
        ("type script", "TypeScript"),
        ("chat g p t|chat gpt|chat g\\.p\\.t\\.", "ChatGPT"),
        ("open ai", "OpenAI"),
        ("super base", "Supabase"),
        ("n 8 n|n eight n|n-8-n", "n8n"),
        ("a p i", "API"),
        ("a p is", "APIs"),
        ("u r l", "URL"),
        ("u r ls", "URLs"),
        ("j son", "JSON"),
        ("my sequel", "MySQL"),
        ("post gres", "Postgres"),
    ]

    public static func apply(_ text: String, custom: [String] = []) -> String {
        var out = text
        for (pattern, replacement) in aliases {
            out = replaceWord(pattern, with: replacement, in: out)
        }
        for term in (builtIn + custom).map({ $0.trimmingCharacters(in: .whitespaces) }) where !term.isEmpty {
            out = replaceWord(NSRegularExpression.escapedPattern(for: term), with: term, in: out)
        }
        return out
    }

    /// The terms handed to Whisper as a spelling hint: the user's own first, then a few of the built-ins.
    public static func hint(custom: [String]) -> [String] {
        var seen = Set<String>()
        return (custom + builtIn).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func replaceWord(_ pattern: String, with replacement: String, in text: String) -> String {
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return text.replacingOccurrences(
            of: "(?<![\\w.@/-])(?:\(pattern))(?![\\w@/-]|\\.\\w)", with: template, options: [.regularExpression, .caseInsensitive])
    }
}
