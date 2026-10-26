import Foundation

/// Handles strong swear words as the last step before pasting, whether or not the AI formatter
/// ran: masks them ("fucking" becomes "f******"), removes them, or leaves them. Mild words
/// ("damn", "hell", "ass") are left alone, and so are words that only contain a swear
/// ("Scunthorpe", "shiitake").
public enum SwearFilter {
    public enum Mode: String, CaseIterable, Identifiable {
        case off, stars, remove

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .off: return "Off"
            case .stars: return "Stars"
            case .remove: return "Remove"
            }
        }

        public var explanation: String {
            switch self {
            case .off: return "Pasted as you said them."
            case .stars: return "Pasted as f***."
            case .remove: return "Left out."
            }
        }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: "\\b(?:"
            + "(?:mother)?fuck\\w*|f+u+c+k+|"
            + "(?:bull|horse|dip|chicken)?shit(?:s|ty|tier|tiest|ting|ted|head|heads|show|shows)?|"
            + "bitch(?:es|ing|y)?|"
            + "(?:dumb|jack|smart)ass(?:es)?|ass(?:hole|holes|wipe|wipes)|"
            + "cunts?|dickheads?|cocksuckers?|bastards?|god ?damn(?:ed|it)?|wtf"
            + ")\\b",
        options: .caseInsensitive)

    /// Punctuation left stranded by removed words: ", ," and " ." collapse, and a sentence
    /// can't start with a comma.
    private static let tidyUps: [(NSRegularExpression, String)] = [
        ("[ \\t]+([.,!?;:])", "$1"),
        ("[,;:]+([.!?])", "$1"),
        ("([,;:])[,;:]+", "$1"),
        ("(^|[.!?]\\s+)[,;:.]+\\s*", "$1"),
        ("[ \\t]{2,}", " "),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.anchorsMatchLines]), $0.1) }

    public static func apply(_ text: String, mode: Mode) -> String {
        guard mode != .off else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let word = result[range]
            if mode == .stars {
                let masked = String(word.prefix(1)) + word.dropFirst().map { $0.isLetter ? "*" : String($0) }.joined()
                result.replaceSubrange(range, with: masked)
                continue
            }
            // Remove the word with the comma and space after it; at the end of a sentence,
            // take the space before it instead.
            let before = result[..<range.lowerBound].last { !$0.isWhitespace }
            let startsSentence = before.map { ".!?".contains($0) } ?? true
            var end = range.upperBound
            if end < result.endIndex, ",;:".contains(result[end]) { end = result.index(after: end) }
            var start = range.lowerBound
            if end < result.endIndex, result[end] == " " {
                end = result.index(after: end)
            } else if start > result.startIndex, result[result.index(before: start)] == " " {
                start = result.index(before: start)
            }
            result.replaceSubrange(start..<end, with: "")
            // "Fuck, this is slow." keeps its capital: "This is slow."
            if startsSentence, start < result.endIndex, result[start].isLowercase {
                result.replaceSubrange(start...start, with: result[start].uppercased())
            }
        }
        guard mode == .remove else { return result }
        for (regex, template) in tidyUps {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
