import AppKit
import SwiftUI

// MARK: - What the dropdown reads and does

/// What BrainDump is doing right now, for the dropdown header.
final class MenuBarStatus: ObservableObject {
    enum Kind { case ready, recording, working, needsPermission, error }

    struct Recording: Identifiable {
        let url: URL
        let label: String
        var id: URL { url }
    }

    @Published var kind: Kind = .ready
    @Published var label = "Ready"
    @Published var recordings: [Recording] = []
}

struct MenuBarActions {
    var openSettings: () -> Void = {}
    var openHistory: () -> Void = {}
    var openTab: (SettingsWindowController.Tab) -> Void = { _ in }
    var grantAccessibility: () -> Void = {}
    var reprocess: (URL) -> Void = { _ in }
    var previewOverlay: () -> Void = {}
    var reloadConfiguration: () -> Void = {}
    var openConfiguration: () -> Void = {}
    var quit: () -> Void = {}
}

// MARK: - Panel

private final class DropdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The menu-bar dropdown: a borderless panel hung under the status item and
/// filled with SwiftUI, in place of the plain macOS menu. It closes on Esc, on a
/// click anywhere else, and when another app takes over.
final class MenuBarPanelController: NSObject {
    static let width: CGFloat = 420
    private static let gapBelowMenuBar: CGFloat = 6

    private let panel: DropdownPanel
    private let host: NSHostingView<MenuBarView>
    private let model: SettingsModel
    private let status: MenuBarStatus
    private let actions: MenuBarActions

    private var anchorX: CGFloat = 0
    private var topY: CGFloat = 0
    private var maxHeight: CGFloat = 600
    private var previousApp: NSRunningApplication?
    private var menuTracking = false
    private var hiddenAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel.isVisible }

    init(model: SettingsModel, status: MenuBarStatus, actions: MenuBarActions) {
        self.model = model
        self.status = status
        self.actions = actions

        let size = NSSize(width: Self.width, height: 480)
        panel = DropdownPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        host = NSHostingView(rootView: MenuBarView(model: model, status: status, actions: actions, maxHeight: 600))
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hide() }

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    func toggle(below button: NSStatusBarButton) {
        if panel.isVisible { hide(); return }
        // The click that just closed it (by taking focus) must not reopen it.
        if Date().timeIntervalSince(hiddenAt) < 0.3 { return }
        show(below: button)
    }

    func show(below button: NSStatusBarButton, expanded: MenuSection? = nil) {
        guard let buttonWindow = button.window else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost

        model.reload()

        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        topY = anchor.minY - Self.gapBelowMenuBar
        anchorX = min(max(anchor.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8)
        maxHeight = max(320, topY - visible.minY - 8)

        host.rootView = MenuBarView(model: model, status: status, actions: actions, maxHeight: maxHeight, expanded: expanded) { [weak self] height in
            self?.resize(to: height)
        }
        panel.setFrame(NSRect(x: anchorX, y: topY - 480, width: Self.width, height: 480), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observe()

        // Fade in once the first measured height arrives, or after a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.fadeIn() }
    }

    /// `restoreFocus` hands the keyboard back to the app you were typing in.
    func hide(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        hiddenAt = Date()
        menuTracking = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if restoreFocus { previousApp?.activate(options: []) }
        previousApp = nil
    }

    private func resize(to height: CGFloat) {
        let h = min(max(height, 120), maxHeight)
        let frame = NSRect(x: anchorX, y: topY - h, width: Self.width, height: h)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        fadeIn()
    }

    private func fadeIn() {
        guard panel.isVisible, panel.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                // A pop-up menu inside the panel also takes key for a moment; only close if it isn't one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let self, self.panel.isVisible, !self.menuTracking, !self.panel.isKeyWindow else { return }
                    self.hide(restoreFocus: false)
                }
            },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuTracking = true
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.menuTracking = false
                DispatchQueue.main.async {
                    guard self.panel.isVisible, !self.panel.isKeyWindow else { return }
                    if NSApp.isActive { self.panel.makeKey() } else { self.hide(restoreFocus: false) }
                }
            },
        ]
    }
}

// MARK: - Dropdown content

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The sections that expand in place. Every setting is one of these: tap the row, pick from the list.
enum MenuSection: String { case hotkey, command, formatting, snippets, dictionary, swearing, speech, language, microphone, dipping, overlay, recordings }

struct MenuBarView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var status: MenuBarStatus
    let actions: MenuBarActions
    let maxHeight: CGFloat
    var onHeightChange: (CGFloat) -> Void
    @State private var open: MenuSection?
    @State private var contentHeight: CGFloat = 0

    init(model: SettingsModel, status: MenuBarStatus, actions: MenuBarActions, maxHeight: CGFloat,
         expanded: MenuSection? = nil, onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.status = status
        self.actions = actions
        self.maxHeight = maxHeight
        self.onHeightChange = onHeightChange
        _open = State(initialValue: expanded)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            VStack(spacing: 10) {
                header
                accessibilityBanner
                controls
                CopyLastButtons(model: model, expand: true)
                footer
            }
            .padding(14)
            .background(GeometryReader { Color.clear.preference(key: MenuHeightKey.self, value: $0.size.height) })
        }
        .frame(width: MenuBarPanelController.width, height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
        .onPreferenceChange(MenuHeightKey.self) { height in
            contentHeight = height
            let capped = min(height, maxHeight)
            // Resizing the window from inside a layout pass isn't allowed.
            DispatchQueue.main.async { onHeightChange(capped) }
        }
        .tint(Theme.accent)
    }

    private func toggle(_ section: MenuSection) {
        open = open == section ? nil : section
    }

    // MARK: Header

    private var statusColor: Color {
        switch status.kind {
        case .ready: return .green
        case .recording, .error: return .red
        case .working, .needsPermission: return .orange
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = SettingsView.appIcon {
                Image(nsImage: icon).resizable().frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("BrainDump").font(.system(size: 14, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(status.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if model.wordsThisWeek > 0 {
                        Text("· \(model.wordsThisWeek.formatted()) words this week · ~\(UsageStats.minutesSaved(words: model.wordsThisWeek)) min saved")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var accessibilityBanner: some View {
        if status.kind == .needsPermission {
            Button(action: actions.grantAccessibility) {
                Label("Grant Accessibility permission…", systemImage: "lock.open").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    // MARK: Controls card

    private var controls: some View {
        VStack(spacing: 0) {
            section(.hotkey, icon: "keyboard", title: "Hotkey", value: model.hotkeySummary) {
                HotkeyPickerView(model: model, compact: true)
            }
            section(.command, icon: "command", title: "Command Mode", value: model.commandKey.title) {
                commandChoices
            }
            section(.formatting, icon: "wand.and.stars", title: "AI formatting",
                    value: model.enabled ? model.style.name + (model.styleByApp ? " · by app" : "") : "Off") {
                formattingChoices
            }
            section(.snippets, icon: "text.badge.plus", title: "Snippets",
                    value: model.snippets.isEmpty ? "None" : "\(model.snippets.count) saved") {
                snippetList
            }
            section(.dictionary, icon: "character.book.closed", title: "Dictionary",
                    value: model.vocabulary.isEmpty ? "None" : "\(model.vocabulary.count) words") {
                dictionaryPreview
            }
            section(.swearing, icon: "asterisk", title: "Swear words", value: model.swearFilter.title) {
                ForEach(SwearFilter.Mode.allCases) { mode in
                    ChoiceRow(title: mode.title, detail: mode.explanation, selected: model.swearFilter == mode) { model.setSwearFilter(mode) }
                }
            }
            section(.speech, icon: "waveform", title: "Speech model", value: model.speechModelSummary) {
                speechModels
            }
            section(.language, icon: "globe", title: "Language", value: model.languageName) {
                languageChoices
            }
            section(.microphone, icon: "mic", title: "Microphone", value: model.selectedInputName) {
                ChoiceRow(title: "System Default", detail: "Whatever your Mac is set to use.", selected: model.inputDeviceID == nil) { model.setInputDevice(nil) }
                ForEach(model.inputDevices, id: \.id) { device in
                    ChoiceRow(title: device.name, selected: model.inputDeviceID == device.id) { model.setInputDevice(device.id) }
                }
            }
            if DipLevel.isAvailable {
                section(.dipping, icon: "speaker.wave.2", title: "Music dipping",
                        value: model.voiceProcessing ? model.dipLevel.title : "Off") {
                    dippingChoices
                }
            }
            section(.overlay, icon: "waveform.path", title: "Recording overlay",
                    value: model.overlayEnabled ? "\(model.overlayPosition.title) · \(model.overlayTheme.title)" : "Off", divider: !status.recordings.isEmpty) {
                overlayChoices
            }
            if !status.recordings.isEmpty {
                section(.recordings, icon: "waveform.circle", title: "Recent recordings", value: "\(status.recordings.count)", divider: false) {
                    ForEach(status.recordings) { recording in
                        Button { actions.reprocess(recording.url) } label: {
                            HStack {
                                Text(recording.label).font(.system(size: 12))
                                Spacer()
                                Text("Transcribe again").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// One row of the card: the setting and its current value; tap to open its choices below it.
    @ViewBuilder
    private func section<Content: View>(_ id: MenuSection, icon: String, title: String, value: String, divider: Bool = true,
                                        @ViewBuilder content: () -> Content) -> some View {
        AccordionRow(icon: icon, title: title, value: value, isOpen: open == id) { toggle(id) }
        if open == id {
            VStack(alignment: .leading, spacing: 4) { content() }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
        }
        if divider { Divider().opacity(0.5) }
    }

    private var speechModels: some View {
        Group {
            ForEach(SpeechTier.allCases) { tier in
                let downloaded = Transcriber.modelExists(modelSize: tier.modelName(language: model.language))
                ChoiceRow(title: tier.title, tag: tier.tagline, highlightTag: tier == .base, detail: tier.detail,
                          note: downloaded ? "Downloaded" : "\(tier.megabytes) MB", noteColor: downloaded ? .green : .secondary,
                          selected: model.speechTier == tier) { model.setSpeechTier(tier) }
            }
            if let custom = model.customSpeechModel {
                Text("Currently using \(custom) from your config file. Pick a size above to switch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var formattingChoices: some View {
        Group {
            ChoiceRow(title: "Off", detail: "Pastes what you said, minus the ums.", selected: !model.enabled) {
                model.enabled = false
                model.save()
            }
            ForEach(FormatStyle.all) { style in
                ChoiceRow(title: style.name, detail: style.blurb, selected: model.enabled && model.styleID == style.id) {
                    model.enabled = true
                    model.selectStyle(style)
                }
            }
            if model.enabled {
                ChoiceRow(title: "Switch style by app",
                          detail: "Claude Prompt in Claude, Terminal and Cursor. Slack in Slack. Email in Mail.",
                          selected: model.styleByApp) { model.setStyleByApp(!model.styleByApp) }
                Button("Choose apps…") { actions.openTab(.apps) }
                    .buttonStyle(.link).font(.system(size: 12))
                    .padding(.horizontal, 10)
                Text("Speed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 6)
                ChoiceRow(title: "Faster", detail: "Quick, and great for everyday dictation.", selected: model.modelName == "fast") {
                    model.modelName = "fast"
                    model.save()
                }
                ChoiceRow(title: "Smarter", detail: "A bit slower. Better with long, messy rambles.", selected: model.modelName == "polished") {
                    model.modelName = "polished"
                    model.save()
                }
                Text("Anything under \(model.minWords) words is pasted without AI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 4)
            }
        }
    }

    private static let commandDetails: [CommandKey: String] = [
        .off: "Hold a key to rewrite highlighted text by voice.",
        .rightcmd: "Hold the right ⌘ key.",
        .rightctrl: "Hold the right ⌃ key.",
        .rightshift: "Hold the right ⇧ key.",
    ]

    private var commandChoices: some View {
        Group {
            ForEach(CommandKey.allCases) { key in
                ChoiceRow(title: key.title, detail: Self.commandDetails[key], selected: model.commandKey == key) { model.setCommandKey(key) }
            }
            Text("Highlight some text, hold the key and say what to do: \"make this shorter\", \"fix the grammar\", \"turn this into bullets\". Let go and it's rewritten. Nothing highlighted? It writes what you ask for. Uses AI formatting's model.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 4)
        }
    }

    private var snippetList: some View {
        Group {
            ForEach(model.snippets.filter { !$0.name.isEmpty }) { snippet in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\"\(snippet.name)\"").font(.system(size: 13, weight: .semibold))
                    Text(snippet.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            Text(model.snippets.isEmpty
                 ? "Save text you use a lot, then paste it by saying its name."
                 : "Say a name as the whole dictation to paste it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 2)
            Button(model.snippets.isEmpty ? "Add a snippet…" : "Add or edit snippets…") { actions.openTab(.snippets) }
                .buttonStyle(.link).font(.system(size: 12))
                .padding(.horizontal, 10)
        }
    }

    private var dictionaryPreview: some View {
        Group {
            Text(model.vocabulary.isEmpty
                 ? "Names and words BrainDump should always spell your way."
                 : model.vocabulary.joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
            Button(model.vocabulary.isEmpty ? "Add words…" : "Edit words…") { actions.openTab(.dictionary) }
                .buttonStyle(.link).font(.system(size: 12))
                .padding(.horizontal, 10)
        }
    }

    /// The most-used languages as choices; the full list lives in "More languages".
    private static let commonLanguages = ["auto", "en", "es", "fr", "de", "pt", "it", "zh", "ja"]

    private var languageChoices: some View {
        Group {
            ForEach(Config.supportedLanguages.filter { Self.commonLanguages.contains($0.code) }, id: \.code) { language in
                ChoiceRow(title: language.name, detail: language.code == "auto" ? "Figures out which language you're speaking." : nil,
                          selected: model.language == language.code) { model.setLanguage(language.code) }
            }
            Menu {
                Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(Config.supportedLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(Self.commonLanguages.contains(model.language) ? "More languages…" : "More languages: \(model.languageName)")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 10).padding(.top, 4)
        }
    }

    private static let dipDetails: [DipLevel: String] = [
        .light: "Music drops a little.",
        .medium: "Music drops into the background.",
        .strong: "Music goes nearly silent.",
    ]

    private var dippingChoices: some View {
        Group {
            ChoiceRow(title: "Off", detail: "Leaves your Mac's sound alone.", selected: !model.voiceProcessing) { model.setVoiceProcessing(false) }
            ForEach(DipLevel.allCases) { level in
                ChoiceRow(title: level.title, detail: Self.dipDetails[level], selected: model.voiceProcessing && model.dipLevel == level) {
                    if !model.voiceProcessing { model.setVoiceProcessing(true) }
                    model.setDipLevel(level)
                }
            }
            Text("Turns down other sound while you record so your mic doesn't pick it up.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 4)
        }
    }

    private var overlayChoices: some View {
        Group {
            ChoiceRow(title: "Show while recording", detail: "A voice bar on your screen while you talk.", selected: model.overlayEnabled) {
                model.setOverlayEnabled(true)
            }
            ChoiceRow(title: "Off", selected: !model.overlayEnabled) { model.setOverlayEnabled(false) }
            if model.overlayEnabled {
                HStack(spacing: 10) {
                    Text("Position").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.overlayPosition.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    PositionGrid(selection: model.overlayPosition) { model.setOverlayPosition($0) }
                }
                .padding(.horizontal, 10).padding(.top, 6)
                HStack(spacing: 10) {
                    Text("Colors").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.overlayTheme.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    ThemeSwatches(selection: model.overlayTheme) { model.setOverlayTheme($0) }
                }
                .padding(.horizontal, 10)
                Button("Preview", action: actions.previewOverlay)
                    .controlSize(.small)
                    .padding(.horizontal, 10).padding(.top, 2)
                    .help("Play the overlay once")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "History", icon: "clock.arrow.circlepath", action: actions.openHistory)
            FooterButton(title: "Settings", icon: "slider.horizontal.3", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Menu {
                Text("BrainDump v\(OpenWispr.version)")
                Divider()
                Button("Reload Configuration", action: actions.reloadConfiguration)
                Button("Open Configuration File", action: actions.openConfiguration)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain).tint(.primary).fixedSize()
            .help("More")
            FooterButton(title: "Quit", icon: "power", action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Pieces

private struct RowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20)
    }
}

private struct AccordionRow: View {
    let icon: String
    let title: String
    let value: String
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RowIcon(name: icon)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One option in an open section: a check, its name (with an optional tag), a line about it,
/// and an optional note on the right. Every section uses it, so they all look and work the same.
private struct ChoiceRow: View {
    let title: String
    var tag: String? = nil
    var highlightTag = false
    var detail: String? = nil
    var note: String? = nil
    var noteColor: Color = .secondary
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if let tag {
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(highlightTag ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.07)))
                                .foregroundStyle(highlightTag ? Color.primary : .secondary)
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(noteColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, detail == nil ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.10) : (hovering ? Color.primary.opacity(0.04) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent.opacity(0.45) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One dot per color scheme, each painted with its own colors; click to pick.
private struct ThemeSwatches: View {
    let selection: OverlayTheme
    let choose: (OverlayTheme) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(OverlayTheme.allCases) { theme in
                Button { choose(theme) } label: {
                    Circle()
                        .fill(LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 14, height: 14)
                        .padding(2)
                        .overlay(Circle().stroke(theme == selection ? Theme.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(theme.title)
            }
        }
    }
}

/// A 3x3 screen map: click where the overlay should appear.
private struct PositionGrid: View {
    let selection: OverlayPosition
    let choose: (OverlayPosition) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { column in
                        let position = OverlayPosition.allCases[row * 3 + column]
                        Button { choose(position) } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(position == selection ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.14)))
                                .frame(width: 16, height: 11)
                        }
                        .buttonStyle(.plain)
                        .help(position.title)
                    }
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Debug render

extension MenuBarPanelController {
    /// Draws the dropdown offscreen to a PNG. `open-wispr render-menu <path> [dark] [hotkey|speech|dip]`.
    static func renderPNG(to path: String, dark: Bool, expanding section: String?) {
        let model = SettingsModel()
        if section == "dip" { model.voiceProcessing = true }
        let status = MenuBarStatus()
        status.label = "Ready"
        let expanded = section.flatMap(MenuSection.init(rawValue:))
        // The real panel sits on a blurred menu background; stand in for it here.
        let hosting = NSHostingView(rootView: MenuBarView(model: model, status: status, actions: MenuBarActions(), maxHeight: 900, expanded: expanded)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = NSSize(width: width, height: 900)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        let fitted = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: min(fitted.height, 900)))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
