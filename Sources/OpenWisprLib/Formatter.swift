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
        guard let result = request(trimmed, settings: settings), !result.isEmpty else {
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
        guard let result = request(trimmed, settings: settings), !result.isEmpty else { return nil }
        return (result, Date().timeIntervalSince(started))
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
            out.append(["role": "user", "content": "<transcript>\n\(ex.transcript)\n</transcript>"])
            out.append(["role": "assistant", "content": ex.output])
        }
        out.append(["role": "user", "content": "<transcript>\n\(transcript)\n</transcript>"])
        return out
    }

    static func clean(_ content: String) -> String {
        var s = content
        if let range = s.range(of: "</think>") {
            s = String(s[range.upperBound...])
        }
        s = s.replacingOccurrences(of: "<transcript>", with: "")
        s = s.replacingOccurrences(of: "</transcript>", with: "")
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
