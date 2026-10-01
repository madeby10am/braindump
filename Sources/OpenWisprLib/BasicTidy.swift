import Foundation

/// Rule-based cleanup for dictation when the AI formatter is off or falls
/// back to the raw transcript. Whisper often drops the period between
/// segments and capitalizes the next segment's first word, which leaves text
/// like "great But the only thing". This repairs that and adds the basics:
/// sentence capitals, a final period or question mark, "I", and dropped
/// um/uh and stuttered function words. It only acts on clear signals and never
/// rewrites words, so it can't change what was said.
public enum BasicTidy {
    public static func tidy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        s = stripFillers(s)
        s = collapseRepeats(s)
        s = repairSegmentBreaks(s)
        s = fixPronounI(s)
        s = splitRunOns(s)
        s = capitalizeSentences(s)
        s = closeLastSentence(s)
        return s
    }

    // MARK: - Fillers and stutters

    /// Removes definite fillers: um/uh, and "you know" / "I mean" / "like" when speech has set them
    /// off with commas ("it was, you know, fine"). "you know what I mean" ends its sentence.
    /// Also used before the AI formatter, so long ramblings reach it already thinned out.
    public static func stripFillers(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "(?i)(?<![\\w'-])(?:u+m+|u+h+|e+r+m+|h+m+|mm+-?h+m+)(?![\\w'-])[,.]?\\s*",
            with: "", options: .regularExpression)
        let rules: [(String, String)] = [
            ("(?i),?\\s*(?<!do )(?<!did )(?<!if )\\byou know what I mean\\b[?.!,]?", "."),
            ("(?i),\\s*you know,", ","),
            ("(?i),\\s*you know\\?", "."),
            ("(?i),\\s*you know(?=[.!])", ""),
            ("(?i)(^|[.!?]\\s+)you know,\\s*", "$1"),
            ("(?i)(^|[.!?,]\\s+)I mean,\\s*", "$1"),
            ("(?i),\\s*like,", ","),
            ("(?i)(^|[.!?]\\s+)like,\\s*", "$1"),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        out = out.replacingOccurrences(of: "\\.(\\s*\\.)+", with: ".", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([,.?!])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "^[,.\\s]+", with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let stutterWords =
        "the|a|an|to|of|in|on|at|for|with|and|that|it|is|was|we|you|I|my|your|so|but|if|this|are|be|can|have|do|they|he|she|there|then|what"

    private static func collapseRepeats(_ s: String) -> String {
        var out = s
        // "the the" -> "the", "I I" -> "I"
        out = out.replacingOccurrences(
            of: "(?i)\\b(\(stutterWords))(\\s+\\1\\b)+", with: "$1", options: .regularExpression)
        // "are the are the" -> "are the", "you can you can" -> "you can"
        out = out.replacingOccurrences(
            of: "(?i)\\b((?:\(stutterWords))\\s+\\w+)(\\s+\\1\\b)+", with: "$1", options: .regularExpression)
        // "take Take" -> "take": the same word twice that differs only in case is a segment-join artifact
        out = out.replacingOccurrences(
            of: "\\b(\\w+)\\s+(?!\\1\\b)(?i:\\1)\\b", with: "$1", options: .regularExpression)
        // Phrases that always end a sentence get their period when Whisper left it out.
        out = out.replacingOccurrences(
            of: "(?i)\\b(you know what I mean|you know what I'm saying|does that make sense|if that makes sense)(?=\\s+[A-Za-z])",
            with: "$1.", options: .regularExpression)
        return out
    }

    // MARK: - Whisper segment breaks

    /// Words that don't end a sentence, so a capital right after one is a
    /// segment boundary in the middle of a sentence ("modes and You know").
    private static let nonFinal: Set<String> = [
        "and", "or", "but", "nor", "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "by", "from",
        "as", "into", "about", "than", "that", "which", "if", "because", "my", "your", "our", "their", "his",
        "her", "its", "i", "we", "is", "are", "was", "were", "be", "been", "will", "would", "should", "could",
        "can", "just", "really", "very", "not", "like",
    ]

    /// Words that start a sentence. Whisper only capitalizes one of these
    /// mid-sentence when it has started a new segment there.
    private static let starters: Set<String> = [
        "and", "but", "so", "now", "yeah", "yes", "no", "okay", "ok", "oh", "then", "because", "also", "basically",
        "anyway", "well", "actually", "maybe", "alright", "wait", "hey", "please", "can", "could", "would",
        "should", "do", "does", "did", "is", "are", "what", "what's", "how", "why", "where", "when", "who", "if",
        "it", "it's", "that", "that's", "this", "there", "there's", "we", "we're", "you", "you're", "they", "let's",
        "let", "make", "go", "take", "put", "get", "change", "add", "push", "check", "look", "try", "use", "remove",
        "update", "fix", "build", "create", "show", "tell", "give", "move", "thanks", "sorry",
    ]

    private static func repairSegmentBreaks(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        guard words.count > 1 else { return s }
        for i in 1..<words.count {
            let word = words[i]
            guard let first = word.first, first.isUppercase else { continue }
            let core = stripPunctuation(word)
            guard core.count > 1, core.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" }) else { continue }
            let lower = core.lowercased()
            guard starters.contains(lower) else { continue }

            let prev = words[i - 1]
            guard isUnpunctuated(prev) else { continue }
            if nonFinal.contains(stripPunctuation(prev).lowercased()) {
                words[i] = word.prefix(1).lowercased() + word.dropFirst()
            } else {
                words[i - 1] = prev + "."
            }
        }
        return words.joined(separator: " ")
    }

    private static func stripPunctuation(_ w: String) -> String {
        w.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"()[]…"))
    }

    /// True when the word has no trailing punctuation, so a sentence could still end after it.
    private static func isUnpunctuated(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return !".!?…,;:".contains(last)
    }

    // MARK: - Pronoun and run-ons

    private static func fixPronounI(_ s: String) -> String {
        s.replacingOccurrences(of: "(?<![\\w'-])i(?=$|[^\\w]|'(?:m|ll|ve|d)\\b)", with: "I", options: .regularExpression)
    }

    /// Unpunctuated runs of speech ("okay so the thing is ... oh this is...")
    /// get a period before an unmistakable new-thought opener, but only after
    /// at least six words so short phrases are left alone.
    private static let openers: Set<String> = ["okay", "alright", "anyway", "yeah", "oh", "also"]

    private static func splitRunOns(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        var runLength = 0
        for i in 0..<words.count {
            let word = words[i]
            if i > 0, runLength >= 6, openers.contains(stripPunctuation(word).lowercased()),
               !nonFinal.contains(stripPunctuation(words[i - 1]).lowercased()),
               isUnpunctuated(words[i - 1]) {
                words[i - 1] += "."
                runLength = 0
            }
            runLength += 1
            if let last = word.last, ".!?…".contains(last) { runLength = 0 }
        }
        return words.joined(separator: " ")
    }

    // MARK: - Capitals and the final stop

    private static func capitalizeSentences(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var capitalizeNext = true
        for (i, ch) in chars.enumerated() {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".!?…".contains(ch), i + 1 == chars.count || chars[i + 1] == " " { capitalizeNext = true }
                else if ch.isLetter || ch.isNumber { capitalizeNext = false }
            }
        }
        return out
    }

    /// "what time is it", "can you check", "is there any way". A wh-word followed by a pronoun
    /// ("what I mean is", "when we ship") is a statement, so it is left alone.
    private static let questionOpener = try! NSRegularExpression(pattern:
        "^(?:(?:what|how|why|where|when|who|which)(?:'s|'re)?\\s+(?!(?:i|we|you|they|he|she|it|that)\\b)"
        + "|(?:can|could|would|will|should|do|does|did|is|are|was|were|have|has|am)\\s+(?:you|we|i|it|they|he|she|there|this|that|the|my|your|anyone|anybody)\\b)",
        options: .caseInsensitive)

    private static func closeLastSentence(_ s: String) -> String {
        guard let last = s.last else { return s }
        if ".!?…".contains(last) || last == ":" || last == ";" { return s }
        if (s.hasPrefix("[") && last == "]") || (s.hasPrefix("(") && last == ")") { return s }
        if "\"')]".contains(last), let before = s.dropLast().last, ".!?…".contains(before) { return s }

        var start = s.startIndex
        if let boundary = s.lastIndex(where: { ".!?…".contains($0) }) {
            start = s.index(after: boundary)
        }
        let sentence = s[start...].trimmingCharacters(in: .whitespaces)
        let range = NSRange(sentence.startIndex..., in: sentence)
        let isQuestion = questionOpener.firstMatch(in: sentence, range: range) != nil
        return s + (isQuestion ? "?" : ".")
    }
}
