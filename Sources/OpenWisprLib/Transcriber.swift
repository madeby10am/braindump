import AVFoundation
import Foundation

public class Transcriber {
    private let modelSize: String
    private let language: String
    private let whisperPrompt: String?
    public var spokenPunctuation: Bool = false

    public init(modelSize: String = "base.en", language: String = "en", whisperPrompt: String? = nil) {
        self.modelSize = modelSize
        self.language = language
        self.whisperPrompt = whisperPrompt
    }

    public func transcribe(audioURL: URL) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw TranscriberError.modelNotFound(modelSize)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments(modelPath: modelPath, audioURL: audioURL, audioDuration: Transcriber.duration(of: audioURL))

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var stderrData = Data()
        let stderrThread = Thread {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        stderrThread.start()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while !stderrThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        process.waitUntilExit()

        let output = Transcriber.stripWhisperMarkers(
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    /// whisper.cpp decodes audio in 30-second windows.
    static let singleWindowSeconds: TimeInterval = 28

    /// Length of a recording, or infinity when it can't be read (which keeps the long-recording settings).
    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return .infinity }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// The hint (prompt) is only used for recordings that fit one decoding window. Across windows it
    /// made whisper.cpp drop or garble words where they meet, which is worse than missing punctuation;
    /// longer recordings keep the settings that decode each window on its own.
    func arguments(modelPath: String, audioURL: URL, audioDuration: TimeInterval = 0) -> [String] {
        let prompt = audioDuration <= Transcriber.singleWindowSeconds ? effectiveWhisperPrompt : nil
        var args = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", language,
            "-nt",
            // Cap the text context carried between 30s windows. whisper.cpp feeds each
            // window's decoded text as the prompt for the next; on long dictation this
            // compounds into repetition/hallucination loops (sentences repeating verbatim,
            // then trailing off). With no prompt the cap is 0, so each window decodes
            // independently. With a prompt it is just big enough for the prompt itself.
            // A cap of 0 would make whisper.cpp ignore the prompt, even with --carry-initial-prompt.
            "-mc", String(prompt.map(Transcriber.contextBudget(forPrompt:)) ?? 0),
        ]
        if let prompt {
            args += ["--prompt", prompt, "--carry-initial-prompt"]
        }
        if spokenPunctuation {
            args += ["--suppress-regex", "[,\\.\\?!;:\\-—]"]
        }

        return args
    }

    /// Context tokens to allow when a prompt is set: the prompt's own length (estimated at
    /// three characters per token, which errs high) plus a small margin, within whisper's limit of 224.
    static func contextBudget(forPrompt prompt: String) -> Int {
        min(224, max(32, (prompt.count + 2) / 3 + 8))
    }

    /// Style-and-spelling hint handed to Whisper when the user hasn't set their own.
    /// Punctuated text steers it toward capitals and full stops, and the term list toward
    /// the right spelling of technical words ("VS Code", "API", "Claude Code"). Kept short so it
    /// fits in a small context budget.
    public static func defaultPrompt(vocabulary: [String]?) -> String {
        let terms = Vocabulary.hint(custom: vocabulary ?? []).prefix(12).joined(separator: ", ")
        return "Hello, this is a voice note. We use \(terms)."
    }

    private var effectiveWhisperPrompt: String? {
        guard let whisperPrompt else { return nil }
        return whisperPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : whisperPrompt
    }

    private static let knownMarkers: Set<String> = [
        "BLANK_AUDIO", "blank_audio",
        "Music", "MUSIC", "music",
        "Applause", "APPLAUSE", "applause",
        "Laughter", "LAUGHTER", "laughter",
        "silence", "Silence", "SILENCE",
        "SOUND", "Sound", "sound",
        "NOISE", "Noise", "noise",
        "INAUDIBLE", "inaudible",
        "Pause", "PAUSE", "pause",
    ]

    private static let markerRegex = try! NSRegularExpression(
        pattern: "[\\[\\(]\\s*([^\\]\\)]+?)\\s*[\\]\\)]"
    )

    public static func stripWhisperMarkers(_ text: String) -> String {
        let nsText = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            let inner = nsText.substring(with: innerRange)
            if knownMarkers.contains(inner) {
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "")
            }
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func findWhisperBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for name in ["whisper-cli", "whisper-cpp"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [name]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result = result, !result.isEmpty {
                return result
            }
        }

        return nil
    }

    public static func modelExists(modelSize: String) -> Bool {
        return findModel(modelSize: modelSize) != nil
    }

    static func findModel(modelSize: String) -> String? {
        let modelFileName = "ggml-\(modelSize).bin"

        let candidates = [
            "\(Config.configDir.path)/models/\(modelFileName)",
            "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
            "/usr/local/share/whisper-cpp/models/\(modelFileName)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}

enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: open-wispr download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
