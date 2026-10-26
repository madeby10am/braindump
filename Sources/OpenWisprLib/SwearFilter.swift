import Foundation

/// Masks strong swear words as the last step before pasting, whether or not the AI formatter ran:
/// "fucking" becomes "f******". Mild words ("damn", "hell", "ass") are left alone, and so are
/// words that only contain a swear ("Scunthorpe", "shiitake").
public enum SwearFilter {
    private static let pattern = try! NSRegularExpression(
        pattern: "\\b(?:"
            + "(?:mother)?fuck\\w*|f+u+c+k+|"
            + "(?:bull|horse|dip|chicken)?shit(?:s|ty|tier|tiest|ting|ted|head|heads|show|shows)?|"
            + "bitch(?:es|ing|y)?|"
            + "(?:dumb|jack|smart)ass(?:es)?|ass(?:hole|holes|wipe|wipes)|"
            + "cunts?|dickheads?|cocksuckers?|bastards?|god ?damn(?:ed|it)?|wtf"
            + ")\\b",
        options: .caseInsensitive)

    public static func apply(_ text: String) -> String {
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let word = result[range]
            let masked = String(word.prefix(1)) + word.dropFirst().map { $0.isLetter ? "*" : String($0) }.joined()
            result.replaceSubrange(range, with: masked)
        }
        return result
    }
}
