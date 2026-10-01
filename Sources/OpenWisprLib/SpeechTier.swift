import Foundation

/// The three speech-recognition sizes BrainDump offers. Behind each one is a
/// Whisper model: "base.en" for English, plain "base" for other languages.
/// Bigger models make fewer mistakes but take longer and use more disk.
public enum SpeechTier: String, CaseIterable, Identifiable {
    case tiny, base, small

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    /// Short headline shown next to the name.
    public var tagline: String {
        switch self {
        case .tiny: return "Fastest"
        case .base: return "Recommended"
        case .small: return "Most accurate"
        }
    }

    /// What it means in everyday use, written for someone who has never heard of Whisper.
    public var detail: String {
        switch self {
        case .tiny: return "Quick notes in a quiet room. Makes more mistakes."
        case .base: return "Fast, and gets most words right. A good fit for everyday talking."
        case .small: return "Better with accents, names and technical words. A little slower."
        }
    }

    public var megabytes: Int {
        switch self {
        case .tiny: return 75
        case .base: return 142
        case .small: return 466
        }
    }

    /// Whisper model file name for this tier and dictation language.
    public func modelName(language: String) -> String {
        language == "en" ? "\(rawValue).en" : rawValue
    }

    /// The tier a model belongs to, ignoring the ".en" and quantization
    /// suffixes ("small.en-q5_1" is still Small). nil for models outside the
    /// three tiers, such as medium or large.
    public static func tier(for modelSize: String) -> SpeechTier? {
        let name = Config.resolveModelAlias(modelSize)
        return allCases.first { name == $0.rawValue || name.hasPrefix($0.rawValue + ".") || name.hasPrefix($0.rawValue + "-") }
    }
}

extension Config {
    /// The model to use after the dictation language changes: English gets
    /// the faster English-only build, every other language the multilingual one.
    public static func modelSize(for language: String, keeping current: String) -> String {
        if let tier = SpeechTier.tier(for: current) {
            return tier.modelName(language: language)
        }
        if language != "en", current.hasSuffix(".en") {
            let multilingual = String(current.dropLast(3))
            if supportedModels.contains(multilingual) { return multilingual }
        }
        if language == "en", !isEnglishOnlyModel(current), supportedModels.contains(current + ".en") {
            return current + ".en"
        }
        return current
    }
}
