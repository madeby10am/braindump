import Foundation

/// Local-LLM cleanup pass for transcripts. Runs a bundled `llama-server`
/// child process on localhost and rewrites brain-dump dictation into a
/// clean, structured prompt. Any failure returns the raw transcript, so
/// dictation never breaks because of the formatter.
public final class Formatter {
    public static let shared = Formatter()

    private var process: Process?
    private var loadedModelPath: String?
    private var port: Int = 8178
    private let lock = NSLock()

    public static func findLlamaServer() -> String? {
        let candidates = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func resolveModelPath(_ settings: FormatterConfig) -> String {
        let path = settings.modelPath
            ?? (FormatterConfig.modelsDir + "/" + settings.preset.file)
        return (path as NSString).expandingTildeInPath
    }

    /// Starts llama-server if formatting is enabled and it is not already
    /// running with the configured model. Safe to call repeatedly.
    public func start(settings: FormatterConfig) {
        lock.lock()
        defer { lock.unlock() }

        guard settings.isEnabled else {
            stopLocked()
            return
        }
        let modelPath = Formatter.resolveModelPath(settings)
        let wantedPort = settings.port ?? FormatterConfig.defaultPort
        if let p = process, p.isRunning, loadedModelPath == modelPath, port == wantedPort {
            return
        }
        stopLocked()

        guard let server = Formatter.findLlamaServer() else {
            print("Formatter: llama-server not found (brew install llama.cpp); formatting disabled")
            return
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            if settings.modelPath == nil {
                downloadThenStart(settings: settings, to: modelPath)
            } else {
                print("Formatter: model not found at \(modelPath); formatting disabled")
            }
            return
        }

        Formatter.killOrphans(port: wantedPort)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: server)
        p.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(wantedPort),
            "-c", "8192",
            "-ngl", "99",
            "--reasoning", "off",
            "--parallel", "1",
            "--log-disable",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p
            loadedModelPath = modelPath
            port = wantedPort
            print("Formatter: started llama-server (pid \(p.processIdentifier)) with \((modelPath as NSString).lastPathComponent)")
        } catch {
            print("Formatter: failed to start llama-server: \(error.localizedDescription)")
        }
    }

    private var downloading = Set<String>()

    /// Fetches a missing preset model in the background, then starts the
    /// server. Until it finishes, dictation pastes the raw transcript.
    private func downloadThenStart(settings: FormatterConfig, to path: String) {
        guard !downloading.contains(path), let url = URL(string: settings.preset.url) else { return }
        downloading.insert(path)
        print("Formatter: downloading \(settings.preset.label) model...")
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.downloading.remove(path)
                self.lock.unlock()
            }
            guard let tmp = tmp, error == nil else {
                print("Formatter: model download failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            let dest = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                print("Formatter: could not save model: \(error.localizedDescription)")
                return
            }
            DispatchQueue.global(qos: .utility).async { self.start(settings: settings) }
        }.resume()
    }

    /// A crashed or force-quit app leaves its llama-server holding the port.
    private static func killOrphans(port: Int) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "llama-server .*--port \(port)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        loadedModelPath = nil
    }

    /// Returns the formatted text, or `text` unchanged when formatting is
    /// off, the input is short, or the server is unavailable/slow.
    public func format(_ text: String, settings: FormatterConfig) -> String {
        formatWithInfo(text, settings: settings).text
    }

    /// Like `format`, plus how long the model took (nil when it didn't run
    /// or fell back to the raw transcript).
    public func formatWithInfo(_ text: String, settings: FormatterConfig) -> (text: String, seconds: Double?) {
        guard settings.isEnabled else { return (text, nil) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= (settings.minWords ?? FormatterConfig.defaultMinWords) else { return (text, nil) }

        let started = Date()
        guard let result = generate(trimmed, settings: settings) else {
            print("Formatter: fell back to raw transcript")
            return (text, nil)
        }
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "Formatter: %d words formatted in %.2fs", words, seconds))
        return (result, seconds)
    }

    /// Formats regardless of the enabled flag and word threshold. Used by the
    /// settings window's "Try it" box. Returns nil on failure.
    public func formatNow(_ text: String, settings: FormatterConfig) -> (text: String, seconds: TimeInterval)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let started = Date()
        guard let result = generate(trimmed, settings: settings) else { return nil }
        return (result, Date().timeIntervalSince(started))
    }

    /// One model call, checked. A small model sometimes answers the dictation instead of
    /// rewriting it (a joke, a translation, advice) or copies words from its examples. Such an
    /// output is rejected: the other styles retry once as Clean Up, and if that fails too the
    /// caller falls back to the speaker's own words. Custom instructions are exempt, since a
    /// custom prompt may legitimately translate or summarize.
    private func generate(_ text: String, settings: FormatterConfig) -> String? {
        guard let first = request(text, settings: settings), !first.isEmpty else { return nil }
        let style = settings.formatStyle
        if style.id == FormatStyle.customID || Formatter.isFaithful(input: text, output: first) { return first }

        print("Formatter: \(style.name) output was not a rewrite of the dictation")
        guard style.id != FormatStyle.cleanUp.id else { return nil }
        var retry = settings
        retry.style = FormatStyle.cleanUp.id
        retry.prompt = nil
        guard let second = request(text, settings: retry), Formatter.isFaithful(input: text, output: second) else { return nil }
        return second
    }

    private static let stopWords: Set<String> = Set("""
        that this with from have what your about there they them then than their would could should which where when \
        while were been being into just like really very also only some more most much many such other another \
        because though although however these those here does doing done will shall gonna wanna kind sort thing \
        things stuff yeah okay actually basically maybe probably can't don't doesn't isn't it's i'm i've i'll i'd \
        you're we're they're that's what's there's let's
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// The words that carry meaning: 4+ letters, not a stop word or number, with a plural/tense ending trimmed.
    static func contentWords(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
            var w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard w.count >= 4, !stopWords.contains(w), !w.allSatisfy({ $0.isNumber }) else { continue }
            for suffix in ["ing", "ed", "es", "s", "ly"] where w.hasSuffix(suffix) && w.count - suffix.count >= 4 {
                w = String(w.dropLast(suffix.count))
                break
            }
            out.insert(w)
        }
        return out
    }

    /// Phrases a model uses when it is answering or refusing instead of rewriting.
    private static let assistantSpeak = try! NSRegularExpression(
        pattern: "\\b(?:i would recommend|i recommend|i'd recommend|i can't|i cannot|i'm sorry|i am sorry|i apologize|as an ai"
            + "|language model|rewriting tool|cleanup tool|here is|here's|here are|certainly|of course|absolutely)\\b|^sure[,!]",
        options: .caseInsensitive)

    private static let placeholder = try! NSRegularExpression(pattern: "\\[[^\\]]+\\]")

    /// A rewrite reuses the speaker's words. Most of the output's meaningful words must come from the
    /// input (precision), and most of the input's must survive (recall). Answers, translations, jokes,
    /// role-play and text copied from a prompt example fail one or both. Assistant phrases ("I recommend",
    /// "I cannot") and [Name] placeholders the speaker never said fail too. Too little text to judge passes.
    static func isFaithful(input: String, output: String) -> Bool {
        let range = NSRange(output.startIndex..., in: output)
        let spoken = input.lowercased()
        if let m = assistantSpeak.firstMatch(in: output, range: range), let r = Range(m.range, in: output),
           !spoken.contains(output[r].lowercased()) { return false }
        if placeholder.firstMatch(in: output, range: range) != nil,
           placeholder.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) == nil { return false }

        let wanted = contentWords(input)
        guard wanted.count >= 5 else { return true }
        let got = contentWords(output)
        guard !got.isEmpty else { return false }
        let shared = Double(wanted.intersection(got).count)
        return shared / Double(got.count) >= 0.65 && shared / Double(wanted.count) >= 0.2
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public var isDownloading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !downloading.isEmpty
    }

    /// True once the model has finished loading and the server answers.
    public func isReady(port: Int = FormatterConfig.defaultPort) -> Bool {
        guard isRunning, let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return ok
    }

    private func request(_ text: String, settings: FormatterConfig) -> String? {
        let port = settings.port ?? FormatterConfig.defaultPort
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return nil }

        let body: [String: Any] = [
            "messages": Formatter.messages(settings: settings, transcript: text),
            "temperature": 0.2,
            "top_p": 0.9,
            "max_tokens": max(256, text.count),
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = settings.timeoutSeconds ?? FormatterConfig.defaultTimeout

        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                print("Formatter: request failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
                print("Formatter: unexpected response from llama-server (HTTP \(status)): \(snippet)")
                return
            }
            output = Formatter.clean(content)
        }.resume()
        semaphore.wait()
        return output
    }

    static func messages(settings: FormatterConfig, transcript: String) -> [[String: String]] {
        let style = settings.formatStyle
        var system = style.prompt
        var examples = style.examples
        if style.id == FormatStyle.customID {
            let custom = settings.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            system = (custom.isEmpty ? FormatStyle.cleanUp.prompt : custom) + FormatStyle.customGuard
            examples = custom.isEmpty ? FormatStyle.cleanUp.examples : []
        }
        var out: [[String: String]] = [["role": "system", "content": system]]
        for ex in examples {
            out.append(["role": "user", "content": FormatStyle.wrap(ex.transcript)])
            out.append(["role": "assistant", "content": ex.output])
        }
        out.append(["role": "user", "content": FormatStyle.wrap(transcript)])
        return out
    }

    static func clean(_ content: String) -> String {
        var s = content
        if let range = s.range(of: "</think>") {
            s = String(s[range.upperBound...])
        }
        for tag in [FormatStyle.inputTag, "transcript"] {
            s = s.replacingOccurrences(of: "<\(tag)>", with: "")
            s = s.replacingOccurrences(of: "</\(tag)>", with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FormatterModel {
    public let name: String
    public let label: String
    public let file: String
    public let url: String
}

public struct FormatterConfig: Codable {
    public static let modelsDir = "~/.config/braindump/models"
    /// Presets shown in the menu. "fast" is the default: ~2x the speed of
    /// "polished" and the most faithful to what was said.
    public static let models: [FormatterModel] = [
        FormatterModel(
            name: "fast", label: "Fast — Gemma 4 E2B",
            file: "gemma-4-e2b-it-qat-q4_k_xl.gguf",
            url: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf"
        ),
        FormatterModel(
            name: "polished", label: "Polished — Qwen3.5 4B",
            file: "qwen3.5-4b-q4_k_m.gguf",
            url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"
        ),
    ]
    public static func preset(named name: String?) -> FormatterModel {
        models.first { $0.name == name } ?? models[0]
    }
    public static let defaultPort = 8178
    public static let defaultMinWords = 15
    public static let defaultTimeout: TimeInterval = 15

    public var enabled: FlexBool?
    /// Preset name from `models` ("fast" or "polished").
    public var model: String?
    /// Optional path to any other GGUF model; overrides `model`.
    public var modelPath: String?
    /// Style id from `FormatStyle.all`; "custom" uses `prompt`.
    public var style: String?
    /// Custom instructions, used when `style` is "custom".
    public var prompt: String?
    public var minWords: Int?
    public var port: Int?
    public var timeoutSeconds: Double?

    public var isEnabled: Bool { enabled?.value ?? true }
    public var preset: FormatterModel { FormatterConfig.preset(named: model) }
    /// Configs from before styles existed that set `prompt` count as custom.
    public var formatStyle: FormatStyle {
        if style == nil, prompt?.isEmpty == false { return FormatStyle.custom }
        return FormatStyle.named(style)
    }

    public init(enabled: FlexBool? = FlexBool(true), model: String? = nil, modelPath: String? = nil, prompt: String? = nil,
                minWords: Int? = nil, port: Int? = nil, timeoutSeconds: Double? = nil) {
        self.enabled = enabled
        self.model = model
        self.modelPath = modelPath
        self.prompt = prompt
        self.minWords = minWords
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }
}
