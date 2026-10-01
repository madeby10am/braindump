import AppKit

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var animationFrames: [NSImage] = []
    private var downloadProgress: String?
    private var downloadPercent: Double = 0
    private let status = MenuBarStatus()
    private var panel: MenuBarPanelController?

    var reprocessHandler: ((URL) -> Void)?
    /// Called on every state change, for the recording overlay.
    var onStateChange: ((State) -> Void)?

    enum State {
        case idle
        case recording
        case transcribing
        case downloading
        case waitingForPermission
        case copiedToClipboard
        case error(String)
    }

    var state: State = .idle {
        didSet {
            updateIcon()
            refresh()
            onStateChange?(state)
        }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusBarController.drawLogo(active: false)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel = MenuBarPanelController(model: SettingsModel.shared, status: status, actions: makeActions())
        refresh()
        openDropdownIfRequested()
    }

    /// Dev aid for screenshots: `BRAINDUMP_OPEN_MENU=1` (or `hotkey` / `speech`) opens the dropdown at launch.
    private func openDropdownIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["BRAINDUMP_OPEN_MENU"], !value.isEmpty else { return }
        let section: MenuSection? = ["hotkey": .hotkey, "speech": .speech][value]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.refreshRecordings()
            self.panel?.show(below: button, expanded: section)
        }
    }

    func updateDownloadProgress(_ text: String?, percent: Double = 0) {
        downloadProgress = text
        downloadPercent = percent
        if case .downloading = state {
            setIcon(StatusBarController.drawDownloadProgress(downloadPercent))
        }
        refresh()
    }

    // MARK: - Dropdown

    /// Updates the dropdown's status line. Safe to call from any thread.
    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh() }
            return
        }
        if let progress = downloadProgress {
            status.label = progress
            status.kind = .working
            return
        }
        switch state {
        case .idle: (status.label, status.kind) = ("Ready", .ready)
        case .recording: (status.label, status.kind) = ("Recording…", .recording)
        case .transcribing: (status.label, status.kind) = ("Transcribing…", .working)
        case .downloading: (status.label, status.kind) = ("Downloading model…", .working)
        case .waitingForPermission: (status.label, status.kind) = ("Waiting for Accessibility permission…", .needsPermission)
        case .copiedToClipboard: (status.label, status.kind) = ("Copied to clipboard", .ready)
        case .error(let message): (status.label, status.kind) = ("Error: \(message)", .error)
        }
    }

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func refreshRecordings() {
        guard Config.effectiveMaxRecordings(Config.load().maxRecordings) > 0 else {
            status.recordings = []
            return
        }
        status.recordings = RecordingStore.listRecordings().enumerated().map { index, recording in
            MenuBarStatus.Recording(
                url: recording.url,
                label: "\(StatusBarController.displayDateFormatter.string(from: recording.date)) (\(index + 1))"
            )
        }
    }

    private func makeActions() -> MenuBarActions {
        MenuBarActions(
            openSettings: { [weak self] in
                self?.panel?.hide(restoreFocus: false)
                SettingsWindowController.shared.show()
            },
            openHistory: { [weak self] in
                self?.panel?.hide(restoreFocus: false)
                SettingsWindowController.shared.show(tab: .history)
            },
            grantAccessibility: { [weak self] in
                self?.panel?.hide(restoreFocus: false)
                Permissions.openAccessibilitySettings()
            },
            reprocess: { [weak self] url in
                self?.panel?.hide()
                self?.reprocessHandler?(url)
            },
            previewOverlay: { (NSApplication.shared.delegate as? AppDelegate)?.overlay.preview() },
            reloadConfiguration: { [weak self] in
                self?.panel?.hide()
                (NSApplication.shared.delegate as? AppDelegate)?.reloadConfig()
            },
            openConfiguration: { [weak self] in
                self?.panel?.hide()
                StatusBarController.openConfigurationFile()
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuickMenu(from: sender)
            return
        }
        refreshRecordings()
        panel?.toggle(below: sender)
    }

    /// Right-click: a plain menu with the two things you can always count on.
    private func showQuickMenu(from button: NSStatusBarButton) {
        panel?.hide(restoreFocus: false)
        let menu = NSMenu()
        let title = NSMenuItem(title: "BrainDump v\(OpenWispr.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromQuickMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettingsFromQuickMenu() {
        SettingsWindowController.shared.show()
    }

    private static func openConfigurationFile() {
        let configFile = Config.configFile
        if !FileManager.default.fileExists(atPath: configFile.path) {
            try? Config.defaultConfig.save()
        }
        NSWorkspace.shared.open(configFile)
    }

    private func updateIcon() {
        stopAnimation()

        switch state {
        case .idle:
            setIcon(StatusBarController.drawLogo(active: false))
        case .recording:
            startRecordingAnimation()
        case .transcribing:
            startTranscribingAnimation()
        case .downloading:
            startDownloadingAnimation()
        case .waitingForPermission:
            setIcon(StatusBarController.drawLockIcon())
        case .copiedToClipboard:
            setIcon(StatusBarController.drawCheckmarkIcon())
        case .error:
            setIcon(StatusBarController.drawWarningIcon())
        }
    }

    // MARK: - Recording animation: wave

    private static let waveFrameCount = 30

    private static func prerenderWaveFrames() -> [NSImage] {
        let count = waveFrameCount
        let baseHeights: [CGFloat] = [4, 8, 12, 8, 4]
        let minScale: CGFloat = 0.3
        let phaseOffsets: [Double] = [0.0, 0.15, 0.3, 0.45, 0.6]

        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

                let barWidth: CGFloat = 2.0
                let gap: CGFloat = 2.5
                let radius: CGFloat = 1.5
                let centerX = rect.midX
                let centerY = rect.midY

                let totalWidth = CGFloat(baseHeights.count) * barWidth + CGFloat(baseHeights.count - 1) * gap
                let startX = centerX - totalWidth / 2

                for (i, baseHeight) in baseHeights.enumerated() {
                    let phase = t - phaseOffsets[i]
                    let scale = minScale + (1.0 - minScale) * CGFloat((sin(phase * 2.0 * .pi) + 1.0) / 2.0)
                    let height = baseHeight * scale
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let y = centerY - height / 2
                    let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                    NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func startRecordingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderWaveFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.waveFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
    }

    // MARK: - Transcribing animation: smooth wave dots

    private static let transcribeFrameCount = 30

    private static func prerenderTranscribeFrames() -> [NSImage] {
        let count = transcribeFrameCount
        let maxBounce: CGFloat = 3.0
        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

                let dotSize: CGFloat = 3
                let gap: CGFloat = 3.0
                let centerY = rect.midY - dotSize / 2
                let totalWidth = 3 * dotSize + 2 * gap
                let startX = rect.midX - totalWidth / 2

                for i in 0..<3 {
                    let phase = t - Double(i) * 0.15
                    let bounce = maxBounce * CGFloat(max(0, sin(phase * 2.0 * .pi)))
                    let x = startX + CGFloat(i) * (dotSize + gap)
                    let y = centerY + bounce
                    let dotRect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
                    NSBezierPath(ovalIn: dotRect).fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func startTranscribingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderTranscribeFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.transcribeFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
    }

    // MARK: - Downloading: progress ring

    private static let downloadPulseFrameCount = 30

    private static func prerenderDownloadPulseFrames() -> [NSImage] {
        let count = downloadPulseFrameCount
        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)
            let alpha = CGFloat(0.4 + 0.6 * (sin(t * 2.0 * .pi) + 1.0) / 2.0)
            return drawDownloadProgress(0, pulseAlpha: alpha)
        }
    }

    private func startDownloadingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderDownloadPulseFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.downloadPercent > 0 {
                self.setIcon(StatusBarController.drawDownloadProgress(self.downloadPercent))
            } else {
                self.animationFrame = (self.animationFrame + 1) % StatusBarController.downloadPulseFrameCount
                self.setIcon(self.animationFrames[self.animationFrame])
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrames = []
    }

    private func setIcon(_ image: NSImage) {
        DispatchQueue.main.async {
            // Each icon sets its own template flag; the idle brain is in color.
            self.statusItem.button?.image = image
        }
    }

    // MARK: - Custom drawn icons

    /// The menu-bar brain, filled with the app icon's violet, crimson and orange.
    static func drawLogo(active: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let brain = NSImage(systemSymbolName: "brain", accessibilityDescription: "BrainDump")?
            .withSymbolConfiguration(config) else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        let gradient = NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.486, green: 0.227, blue: 0.929, alpha: 1), 0),   // #7C3AED
            (NSColor(srgbRed: 0.859, green: 0.153, blue: 0.467, alpha: 1), 0.55), // #DB2777
            (NSColor(srgbRed: 0.976, green: 0.451, blue: 0.086, alpha: 1), 1)     // #F97316
        )
        let image = NSImage(size: brain.size, flipped: false) { rect in
            brain.draw(in: rect)
            // Keep the gradient only where the brain was drawn.
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            gradient?.draw(in: rect, angle: -45)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "BrainDump"
        return image
    }

    static func drawDownloadProgress(_ percent: Double, pulseAlpha: CGFloat = 1.0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.5
            let lineWidth: CGFloat = 1.8

            NSColor.black.withAlphaComponent(0.25 * pulseAlpha).setStroke()
            let bgCircle = NSBezierPath()
            bgCircle.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            bgCircle.lineWidth = lineWidth
            bgCircle.stroke()

            if percent > 0 {
                NSColor.black.setStroke()
                let progressArc = NSBezierPath()
                let startAngle: CGFloat = 90
                let endAngle = startAngle - CGFloat(percent / 100.0) * 360.0
                progressArc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                progressArc.lineWidth = lineWidth
                progressArc.lineCapStyle = .round
                progressArc.stroke()
            }

            NSColor.black.withAlphaComponent(pulseAlpha).setStroke()
            NSColor.black.withAlphaComponent(pulseAlpha).setFill()
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: center.x, y: center.y + 3))
            arrowPath.line(to: NSPoint(x: center.x, y: center.y - 3))
            arrowPath.lineWidth = 1.5
            arrowPath.lineCapStyle = .round
            arrowPath.stroke()

            let headPath = NSBezierPath()
            headPath.move(to: NSPoint(x: center.x - 2.5, y: center.y - 0.5))
            headPath.line(to: NSPoint(x: center.x, y: center.y - 3.5))
            headPath.line(to: NSPoint(x: center.x + 2.5, y: center.y - 0.5))
            headPath.lineWidth = 1.5
            headPath.lineCapStyle = .round
            headPath.lineJoinStyle = .round
            headPath.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawLockIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX

            let bodyRect = NSRect(x: centerX - 4, y: 2, width: 8, height: 7)
            NSBezierPath(roundedRect: bodyRect, xRadius: 1.5, yRadius: 1.5).fill()

            let shacklePath = NSBezierPath()
            shacklePath.move(to: NSPoint(x: centerX - 2.5, y: 9))
            shacklePath.curve(to: NSPoint(x: centerX + 2.5, y: 9),
                              controlPoint1: NSPoint(x: centerX - 2.5, y: 15),
                              controlPoint2: NSPoint(x: centerX + 2.5, y: 15))
            shacklePath.lineWidth = 1.8
            shacklePath.lineCapStyle = .round
            shacklePath.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawCheckmarkIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()

            let centerX = rect.midX
            let centerY = rect.midY

            let path = NSBezierPath()
            path.move(to: NSPoint(x: centerX - 5, y: centerY + 1))
            path.line(to: NSPoint(x: centerX - 2, y: centerY - 3))
            path.line(to: NSPoint(x: centerX + 5, y: centerY + 4))
            path.lineWidth = 2.0
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawWarningIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX

            // Triangle outline
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: centerX, y: 16))
            triangle.line(to: NSPoint(x: centerX - 7, y: 3))
            triangle.line(to: NSPoint(x: centerX + 7, y: 3))
            triangle.close()
            triangle.lineWidth = 1.5
            triangle.lineJoinStyle = .round
            triangle.stroke()

            // Exclamation mark
            let stemRect = NSRect(x: centerX - 0.75, y: 7, width: 1.5, height: 5)
            NSBezierPath(roundedRect: stemRect, xRadius: 0.75, yRadius: 0.75).fill()
            let dotRect = NSRect(x: centerX - 1, y: 4.5, width: 2, height: 2)
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}
