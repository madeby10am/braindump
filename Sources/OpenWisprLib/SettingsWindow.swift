import AppKit
import SwiftUI

// MARK: - Window

/// The BrainDump settings window: formatting style, custom instructions,
/// model choice, and a live "Try it" box that runs the real formatter.
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var model: SettingsModel?

    public enum Tab: String { case formatting, history }

    public func show(tab: Tab? = nil) {
        DispatchQueue.main.async {
            self.showOnMain()
            if let tab = tab { self.model?.tab = tab }
        }
    }

    private func showOnMain() {
        installEditMenu()
        if window == nil {
            let model = SettingsModel()
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "BrainDump"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = hosting
            w.minSize = NSSize(width: 760, height: 620)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            self.model = model
        } else {
            model?.reload()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Debug: draws the settings UI offscreen to a PNG (no screen-recording
    /// permission needed). `open-wispr render-settings <path> [dark]`.
    public static func renderPNG(to path: String, dark: Bool, tab: Tab = .formatting, hotkeyPicker: Bool = false) {
        let model = SettingsModel()
        model.tab = tab
        model.stopPolling()
        model.serverStatus = .ready
        model.tryOutput = "I want you to do three things:\n\n1. Check my email.\n2. Add the dentist appointment to my calendar for Friday.\n3. Make me a grocery list: eggs, milk, and coffee."
        model.tryInfo = "1.2s · Fast — Gemma 4 E2B"
        let hosting: NSView
        let size: NSSize
        if hotkeyPicker {
            hosting = NSHostingView(rootView: HotkeyPickerView(model: model).frame(width: 640))
            size = NSSize(width: 640, height: 470)
        } else {
            hosting = NSHostingView(rootView: SettingsView(model: model))
            size = NSSize(width: 860, height: 700)
        }
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.appearance = hosting.appearance
        w.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    public func windowWillClose(_ notification: Notification) {
        model?.stopPolling()
        // Back to a menu-bar-only app once the window is gone.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Menu-bar apps have no main menu, so Cmd+C/V/X/A/Z do nothing in text
    /// fields unless an Edit menu exists.
    private func installEditMenu() {
        guard NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
        let main = NSApp.mainMenu ?? NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit BrainDump", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    enum ServerStatus: Equatable {
        case off, loading, downloading, ready, missing
    }

    @Published var enabled = true
    @Published var modelName = FormatterConfig.models[0].name
    @Published var styleID = FormatStyle.cleanUp.id
    @Published var customPrompt = ""
    @Published var minWords = FormatterConfig.defaultMinWords
    @Published var serverStatus: ServerStatus = .loading
    @Published var hotkey = ""
    @Published var tab: SettingsWindowController.Tab = .formatting
    @Published var appearance = "system"
    @Published var history: [DictationRecord] = []
    @Published var copiedID: String?
    @Published var hotkeyCode: UInt16 = 63
    @Published var hotkeyMods: [String] = []
    @Published var hotkeyMode: Config.HotkeyMode = .hold
    @Published var showHotkeyPicker = false

    @Published var tryInput = "okay so um I need you to like check my email and then uh add the dentist thing to my calendar for friday and also like make me a grocery list eggs milk coffee you know"
    @Published var tryOutput = ""
    @Published var tryInfo = ""
    @Published var isTrying = false

    /// Custom prompt as last saved, to show an "unsaved" state.
    @Published var savedCustomPrompt = ""

    private var pollTimer: Timer?
    private var historyObserver: NSObjectProtocol?

    init() {
        reload()
        historyObserver = NotificationCenter.default.addObserver(
            forName: History.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.history = History.load()
        }
    }

    deinit {
        if let o = historyObserver { NotificationCenter.default.removeObserver(o) }
    }

    func setAppearance(_ value: String) {
        appearance = value
        var config = Config.load()
        config.appearance = value == "system" ? nil : value
        try? config.save()
        Config.applyAppearance(config.appearance)
    }

    var hotkeySummary: String { "\(hotkey) · \(Config.modeLabel(hotkeyMode))" }

    var hotkeyWarning: String? {
        let isModifier = KeyDef.modifierCodes.contains(hotkeyCode)
        let isFunctionKey = [53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105].contains(Int(hotkeyCode))
        if !isModifier && !isFunctionKey && hotkeyMods.isEmpty {
            return "\(hotkey) on its own will stop typing that key normally. Add a modifier like ⌃ or ⌥, or pick a modifier or F-key."
        }
        return nil
    }

    func setHotkey(code: UInt16, modifiers: [String]) {
        var config = Config.load()
        config.hotkeys = [HotkeyConfig(keyCode: code, modifiers: modifiers)]
        try? config.save()
        hotkeyCode = code
        hotkeyMods = modifiers
        hotkey = MacKeyboard.describe(code: code, modifiers: modifiers)
        let saved = config
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.applyConfigChange(saved) }
    }

    func setHotkeyMode(_ mode: Config.HotkeyMode) {
        var config = Config.load()
        config.setHotkeyMode(mode)
        try? config.save()
        hotkeyMode = mode
        let saved = config
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.applyConfigChange(saved) }
    }

    func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func clearHistory() {
        History.clear()
        history = []
    }

    func reload() {
        let config = Config.load()
        let f = config.formatterSettings
        enabled = f.isEnabled
        modelName = f.preset.name
        styleID = f.formatStyle.id
        customPrompt = f.prompt ?? ""
        savedCustomPrompt = customPrompt
        minWords = f.minWords ?? FormatterConfig.defaultMinWords
        hotkeyCode = config.hotkey.keyCode
        hotkeyMods = config.hotkey.modifiers
        hotkeyMode = config.effectiveHotkeyMode
        hotkey = MacKeyboard.describe(code: hotkeyCode, modifiers: hotkeyMods)
        appearance = config.appearance ?? "system"
        history = History.load()
        startPolling()
    }

    var style: FormatStyle { FormatStyle.named(styleID) }
    var isCustom: Bool { styleID == FormatStyle.customID }
    var customDirty: Bool { isCustom && customPrompt != savedCustomPrompt }

    /// The settings as currently shown, whether or not they are saved.
    var draft: FormatterConfig {
        var f = Config.load().formatterSettings
        f.enabled = FlexBool(enabled)
        f.model = modelName
        f.modelPath = nil
        f.style = styleID
        f.prompt = customPrompt
        f.minWords = minWords
        return f
    }

    func save() {
        var config = Config.load()
        config.formatter = draft
        try? config.save()
        savedCustomPrompt = customPrompt
        let saved = config
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.applyConfigChange(saved)
        }
        refreshStatus()
    }

    func selectStyle(_ s: FormatStyle) {
        if s.id == FormatStyle.customID, customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customPrompt = style.id == FormatStyle.customID ? FormatStyle.cleanUp.prompt : style.prompt
        }
        styleID = s.id
        save()
    }

    /// Copies the current preset's instructions into Custom for editing.
    func customizeCurrent() {
        customPrompt = style.prompt
        styleID = FormatStyle.customID
        save()
    }

    func runTry() {
        guard !isTrying else { return }
        isTrying = true
        tryOutput = ""
        tryInfo = "Formatting…"
        let settings = draft
        let input = tryInput
        DispatchQueue.global(qos: .userInitiated).async {
            if !Formatter.shared.isRunning {
                Formatter.shared.start(settings: settings)
            }
            var waited = 0
            while !Formatter.shared.isReady() && waited < 120 {
                Thread.sleep(forTimeInterval: 0.25)
                waited += 1
            }
            let result = Formatter.shared.formatNow(input, settings: settings)
            DispatchQueue.main.async {
                self.isTrying = false
                if let r = result {
                    self.tryOutput = r.text
                    self.tryInfo = String(format: "%.1fs · %@", r.seconds, FormatterConfig.preset(named: settings.model).label)
                } else {
                    self.tryInfo = "The model isn't ready yet. Try again in a few seconds."
                }
                self.refreshStatus()
            }
        }
    }

    func startPolling() {
        refreshStatus()
        pollTimer?.invalidate()
        // Local health check only while the window is open.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refreshStatus() {
        let enabled = self.enabled
        DispatchQueue.global(qos: .utility).async {
            let status: ServerStatus
            if !enabled {
                status = .off
            } else if Formatter.shared.isDownloading {
                status = .downloading
            } else if Formatter.findLlamaServer() == nil {
                status = .missing
            } else if Formatter.shared.isReady() {
                status = .ready
            } else {
                status = .loading
            }
            DispatchQueue.main.async { self.serverStatus = status }
        }
    }
}

// MARK: - Theme

enum Theme {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.86, green: 0.15, blue: 0.47), Color(red: 0.98, green: 0.45, blue: 0.09)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let accent = Color(red: 0.75, green: 0.15, blue: 0.83)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color.primary.opacity(0.08)
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    static let appIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let img = NSImage(contentsOf: url) {
            return img
        }
        let repoIcon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcon.icns")
        return NSImage(contentsOf: repoIcon) ?? NSApp.applicationIconImage
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.tab == .formatting {
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                        .frame(width: 250)
                    Divider().opacity(0.5)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            instructions
                            tryIt
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                    }
                }
                Divider().opacity(0.5)
                footer
            } else {
                HistoryView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.accent)
    }

    // Header: logo, name, status, master switch.
    private var header: some View {
        HStack(spacing: 14) {
            if let icon = SettingsView.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("BrainDump")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Talk messy. Paste clean.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.tab) {
                Text("Formatting").tag(SettingsWindowController.Tab.formatting)
                Text("History").tag(SettingsWindowController.Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Spacer()
            Button {
                model.showHotkeyPicker.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard")
                    Text(model.hotkeySummary).font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
            }
            .buttonStyle(.plain)
            .help("Change hotkey")
            .popover(isPresented: $model.showHotkeyPicker, arrowEdge: .bottom) {
                HotkeyPickerView(model: model)
            }
            Menu {
                Picker("Appearance", selection: Binding(
                    get: { model.appearance },
                    set: { model.setAppearance($0) }
                )) {
                    Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: model.appearance == "light" ? "sun.max" : (model.appearance == "dark" ? "moon" : "circle.lefthalf.filled"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Appearance")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // Sidebar: style presets.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STYLE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.bottom, 2)
            ForEach(FormatStyle.all) { s in
                StyleCard(style: s, selected: s.id == model.styleID) {
                    model.selectStyle(s)
                }
            }
            Spacer()
        }
        .padding(16)
        .opacity(model.enabled ? 1 : 0.45)
        .disabled(!model.enabled)
    }

    // Instructions: read-only preset text, or the editable custom prompt.
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Instructions", subtitle: model.isCustom
                    ? "Tell the model exactly how to rewrite your dictation."
                    : "What the \(model.style.name) style tells the model.")
                Spacer()
                if model.isCustom {
                    Button("Save") { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.customDirty)
                } else {
                    Button {
                        model.customizeCurrent()
                    } label: {
                        Label("Customize", systemImage: "pencil")
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                if model.isCustom {
                    TextEditor(text: $model.customPrompt)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                } else {
                    ScrollView {
                        Text(model.style.prompt)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.customDirty ? Theme.accent.opacity(0.6) : Theme.stroke))

            if model.isCustom {
                Text(model.customDirty
                     ? "Unsaved changes. Press ⌘S to save. \"Try it\" already uses what you've typed."
                     : "BrainDump always adds a guard so the model rewrites your words and never answers them.")
                    .font(.system(size: 11))
                    .foregroundStyle(model.customDirty ? Theme.accent : .secondary)
            }
        }
    }

    // Try it: runs the real formatter on sample text.
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Try it", subtitle: "Paste or type a brain dump and see what gets pasted.")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You say").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $model.tryInput)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 140)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("BrainDump pastes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(model.tryOutput.isEmpty ? " " : model.tryOutput)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(height: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.accent.opacity(0.06))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.25)))
                    .overlay {
                        if model.isTrying { ProgressView().controlSize(.small) }
                    }
                }
            }
            HStack {
                Button {
                    model.runTry()
                } label: {
                    Label("Format", systemImage: "wand.and.stars")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isTrying || !model.enabled)
                Text(model.tryInfo)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // Footer: formatter status + switch, model, threshold.
    private var footer: some View {
        HStack(spacing: 18) {
            Toggle(isOn: Binding(
                get: { model.enabled },
                set: { model.enabled = $0; model.save() }
            )) {
                Text("AI Formatting").font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            StatusPill(status: model.serverStatus)
            Divider().frame(height: 18)
            HStack(spacing: 8) {
                Text("Model").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .fixedSize()
                Picker("", selection: Binding(
                    get: { model.modelName },
                    set: { model.modelName = $0; model.save() }
                )) {
                    ForEach(FormatterConfig.models, id: \.name) { m in
                        Text(m.name == "fast" ? "Fast" : "Polished").tag(m.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help(FormatterConfig.preset(named: model.modelName).label)
                .disabled(!model.enabled)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Skip under").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .fixedSize()
                Stepper(value: Binding(
                    get: { model.minWords },
                    set: { model.minWords = $0; model.save() }
                ), in: 0...100, step: 5) {
                    Text("\(model.minWords) words").font(.system(size: 12, design: .monospaced))
                }
            }
            .disabled(!model.enabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClear = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionTitle(title: "History", subtitle: "Your last \(History.maxEntries) dictations, raw and formatted. Stored only on this Mac.")
                Spacer()
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.history.isEmpty)
                .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear) {
                    Button("Clear History", role: .destructive) { model.clearHistory() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if model.history.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No dictations yet").font(.system(size: 14, weight: .semibold))
                    Text("Hold your hotkey and start talking.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.history) { r in
                            HistoryRow(record: r, model: model, time: HistoryView.timeFormatter.string(from: r.date))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @ObservedObject var model: SettingsModel
    let time: String
    @State private var showRaw = false

    private var badge: String {
        guard let style = record.style else { return "Pasted raw" }
        var parts = [style]
        if let m = record.model { parts.append(m.components(separatedBy: " — ").first ?? m) }
        if let s = record.seconds { parts.append(String(format: "%.1fs", s)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(time).font(.system(size: 12, weight: .semibold))
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(record.wasFormatted ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.07)))
                    .foregroundStyle(record.wasFormatted ? Theme.accent : .secondary)
                Spacer()
                copyButton("Copy", text: record.output, id: record.id.uuidString + "-out")
                if record.wasFormatted {
                    copyButton("Copy raw", text: record.raw, id: record.id.uuidString + "-raw")
                }
            }
            Text(record.output)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if record.wasFormatted {
                DisclosureGroup(isExpanded: $showRaw) {
                    Text(record.raw)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text("What you said").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }

    private func copyButton(_ title: String, text: String, id: String) -> some View {
        Button {
            model.copy(text, id: id)
        } label: {
            Label(model.copiedID == id ? "Copied" : title, systemImage: model.copiedID == id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct StyleCard: View {
    let style: FormatStyle
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
                    Image(systemName: style.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .white : .secondary)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name).font(.system(size: 13, weight: .semibold))
                    Text(style.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Theme.accent.opacity(0.10) : (hovering ? Color.primary.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StatusPill: View {
    let status: SettingsModel.ServerStatus

    private var label: String {
        switch status {
        case .off: return "Formatting off"
        case .loading: return "Loading model…"
        case .downloading: return "Downloading model…"
        case .ready: return "Model ready"
        case .missing: return "llama.cpp missing"
        }
    }

    private var color: Color {
        switch status {
        case .ready: return .green
        case .loading, .downloading: return .orange
        case .off: return .secondary
        case .missing: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Theme.gradient))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}
