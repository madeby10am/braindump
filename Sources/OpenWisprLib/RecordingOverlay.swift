import AppKit
import SwiftUI

/// Where on the screen the overlay appears. The cases run left to right, top to bottom.
public enum OverlayPosition: String, CaseIterable, Identifiable {
    case topLeft = "top-left", top, topRight = "top-right"
    case left, center, right
    case bottomLeft = "bottom-left", bottom, bottomRight = "bottom-right"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top"
        case .topRight: return "Top right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom right"
        }
    }

    /// -1 left, 0 middle, 1 right.
    var column: Int { (Self.allCases.firstIndex(of: self) ?? 1) % 3 - 1 }
    /// -1 top, 0 middle, 1 bottom.
    var row: Int { (Self.allCases.firstIndex(of: self) ?? 1) / 3 - 1 }
}

// MARK: - Colors

/// The overlay's color scheme. Each one is three colors running left to right along the bars,
/// on a dark or a light bubble.
public enum OverlayTheme: String, CaseIterable, Identifiable {
    case white, light, brainDump = "braindump", ocean, sunset, forest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .brainDump: return "BrainDump"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        case .white: return "White"
        case .light: return "Light"
        }
    }

    typealias RGB = (Double, Double, Double)

    var stops: [RGB] {
        switch self {
        case .brainDump: return [(0.62, 0.42, 1.0), (1.0, 0.32, 0.58), (1.0, 0.60, 0.22)]
        case .ocean: return [(0.30, 0.85, 1.0), (0.25, 0.50, 1.0), (0.55, 0.40, 1.0)]
        case .sunset: return [(1.0, 0.82, 0.30), (1.0, 0.52, 0.22), (1.0, 0.28, 0.35)]
        case .forest: return [(0.65, 0.95, 0.40), (0.25, 0.85, 0.55), (0.20, 0.75, 0.80)]
        case .white: return [(1, 1, 1), (0.93, 0.93, 0.95), (0.86, 0.86, 0.90)]
        case .light: return [(0.10, 0.10, 0.12), (0.18, 0.18, 0.21), (0.28, 0.28, 0.31)]
        }
    }

    var isLight: Bool { self == .light }

    /// The color at `x` (0 at the mic, 1 at the far end).
    func color(at x: Double) -> Color {
        let s = stops
        let (a, b, f) = x < 0.5 ? (s[0], s[1], x * 2) : (s[1], s[2], (x - 0.5) * 2)
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    var colors: [Color] { [color(at: 0), color(at: 0.5), color(at: 1)] }
    var accent: Color { color(at: 0.5) }
    var bubble: Color { isLight ? Color(white: 0.97) : Color(red: 0.05, green: 0.05, blue: 0.07) }
    var micFill: Color { isLight ? Color.white : Color(red: 0.11, green: 0.11, blue: 0.14) }
    var ink: Color { isLight ? Color(white: 0.1) : Color.white }
    var outline: Color { isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.08) }
}

// MARK: - Model

/// What the overlay is showing right now.
final class RecordingOverlayModel: ObservableObject {
    enum Phase { case recording, thinking }

    @Published var phase: Phase = .recording
    /// Smoothed microphone loudness, 0...1, while recording.
    @Published var level: Double = 0
    /// Recent loudness, newest first (about 1.4 seconds at 60 samples a second).
    @Published var history: [Double] = Array(repeating: 0, count: RecordingOverlayModel.historyLength)
    static let historyLength = 84
    /// Reference-date seconds, so the view can ease between looks.
    @Published var phaseChangedAt: Double = 0
    @Published var appearedAt: Double = 0
    /// False while the panel is hidden, so the animation clock stops.
    @Published var isActive = false
    @Published var theme: OverlayTheme = .white
}

// MARK: - Controller

/// A click-through panel near the top of the screen: a slim bar whose voice bars
/// follow you while you talk, and pulse while BrainDump works out what you said
/// ("thinking"). It never takes focus.
final class RecordingOverlayController {
    /// The panel, with room around the bar for its glow and shadow.
    static let width: CGFloat = 300
    static let height: CGFloat = 104
    /// Gap between the bar and the edge of the usable screen.
    private static let edgeMargin: CGFloat = 14

    private let panel: NSPanel
    private let model = RecordingOverlayModel()
    private var levelTimer: Timer?
    private var smoothed = 0.0
    private var visible = false
    private var previewing = false
    private var previewSteps: [DispatchWorkItem] = []

    var isEnabled = true {
        didSet { if !isEnabled { dismiss(immediately: true) } }
    }
    var position: OverlayPosition = .top
    var theme: OverlayTheme {
        get { model.theme }
        set { model.theme = newValue }
    }
    /// Current microphone peak, 0...1.
    var levelProvider: () -> Float = { 0 }

    init() {
        let size = NSSize(width: Self.width, height: Self.height)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
    }

    /// Follows the menu-bar icon's state: recording shows your voice,
    /// transcribing shows the thinking pulse, anything else hides it.
    func update(for state: StatusBarController.State) {
        switch state {
        case .recording:
            cancelPreview()
            present(.recording)
        case .transcribing:
            cancelPreview()
            present(.thinking)
        default:
            if previewing { return }
            dismiss()
        }
    }

    /// Plays the whole thing once so you can see it without dictating.
    /// `brief` just flashes it, to show where it will appear.
    func preview(brief: Bool = false) {
        cancelPreview()
        previewing = true
        dismiss(immediately: true)
        present(.recording, force: true)
        if !brief { schedule(after: 2.8) { [weak self] in self?.present(.thinking, force: true) } }
        schedule(after: brief ? 1.8 : 5.0) { [weak self] in
            self?.previewing = false
            self?.dismiss()
        }
    }

    // MARK: Showing and hiding

    private func present(_ phase: RecordingOverlayModel.Phase, force: Bool = false) {
        guard isEnabled || force else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if !visible {
            model.phase = phase
            model.phaseChangedAt = -1000
            model.appearedAt = now
            model.level = 0
            smoothed = 0
            place()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            model.isActive = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
            visible = true
        } else if model.phase != phase {
            model.phase = phase
            model.phaseChangedAt = now
        }
        updateLevelTimer()
    }

    private func dismiss(immediately: Bool = false) {
        guard visible else { return }
        visible = false
        updateLevelTimer()
        if immediately {
            panel.orderOut(nil)
            model.isActive = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
            self.model.isActive = false
        })
    }

    /// The chosen spot on whichever screen the pointer is on. Dock and menu bar are left clear.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let usable = screen.visibleFrame
        let (width, height) = (Self.width, Self.height)
        let insetX = RecordingOverlayView.barWidth / 2 + Self.edgeMargin
        let insetY = RecordingOverlayView.barHeight / 2 + Self.edgeMargin
        let centerX: CGFloat
        switch position.column {
        case -1: centerX = usable.minX + insetX
        case 1: centerX = usable.maxX - insetX
        default: centerX = usable.midX
        }
        let centerY: CGFloat
        switch position.row {
        case -1: centerY = usable.maxY - insetY
        case 1: centerY = usable.minY + insetY
        default: centerY = usable.midY
        }
        panel.setFrame(NSRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height), display: false)
    }

    // MARK: Voice level

    private func updateLevelTimer() {
        if visible, model.phase == .recording {
            guard levelTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tickLevel() }
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } else {
            levelTimer?.invalidate()
            levelTimer = nil
            smoothed = 0
            model.level = 0
            model.history = Array(repeating: 0, count: RecordingOverlayModel.historyLength)
        }
    }

    private func tickLevel() {
        let raw: Double
        if previewing {
            // Pretend to talk: bursts like words with short pauses between.
            let t = Date.timeIntervalSinceReferenceDate
            let word = max(0, sin(t * 1.7))
            let syllable = 0.55 + 0.45 * abs(sin(t * 9.0))
            raw = min(1, word * syllable * 1.2)
        } else {
            // Ignore room noise, then stretch quiet speech so it moves the effect.
            raw = min(1, pow(max(0, (Double(levelProvider()) - 0.012) / 0.22), 0.6))
        }
        // Jump up with the voice, fall back a little slower (rates per 1/60 s tick).
        smoothed = raw > smoothed ? smoothed * 0.55 + raw * 0.45 : smoothed * 0.906 + raw * 0.094
        model.level = smoothed
        model.history = [smoothed] + model.history.dropLast()
    }

    // MARK: Preview plumbing

    private func schedule(after seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        previewSteps.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelPreview() {
        previewSteps.forEach { $0.cancel() }
        previewSteps = []
        previewing = false
    }
}

// MARK: - View

/// A slim dark bar: a mic in a circle on the left, your voice as bars running to the right.
/// The bar's outline swells around loud bars, so the whole bubble moves with your voice.
struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel
    /// Freezes the animation at one moment, for screenshots.
    var fixedTime: Double?

    static let barWidth: CGFloat = 268
    static let barHeight: CGFloat = 44
    private static let micSize: CGFloat = 34
    /// How far the bubble can swell above and below its resting edge.
    private static let maxSwell: CGFloat = 12
    private static let barCount = 32

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isActive && fixedTime == nil)) { timeline in
            let t = fixedTime ?? timeline.date.timeIntervalSinceReferenceDate
            let appear = Self.easeOutBack(Self.clamp((t - model.appearedAt) / 0.4))
            let blend = Self.smooth(Self.clamp((t - model.phaseChangedAt) / 0.5))
            let speaking = model.phase == .recording ? blend : 1 - blend
            let thinking = 1 - speaking
            let level = model.level
            let history = model.history
            let theme = model.theme

            let bars = Self.layoutBars(t: t, history: history, speaking: speaking, thinking: thinking, theme: theme)
            let bubble = VoiceBubble(radius: Self.barHeight / 2, edge: bars.map { CGPoint(x: $0.x, y: $0.swell) })

            ZStack(alignment: .leading) {
                bubble
                    .fill(theme.bubble.opacity(0.94))
                    .overlay(bubble.stroke(theme.outline, lineWidth: 1))
                    .shadow(color: .black.opacity(theme.isLight ? 0.18 : 0.45), radius: 10, y: 4)
                    .shadow(color: theme.accent.opacity(0.45 * level * speaking), radius: 4 + 12 * level)
                Canvas { context, size in
                    Self.drawBars(&context, size: size, bars: bars, highlight: !theme.isLight)
                }
                mic(t: t, level: level, speaking: speaking, thinking: thinking, theme: theme)
                    .padding(.leading, 5)
            }
            .frame(width: Self.barWidth, height: Self.barHeight + 2 * Self.maxSwell)
            .scaleEffect(0.85 + 0.15 * appear)
            .opacity(min(1, appear * 1.5))
        }
        .frame(width: RecordingOverlayController.width, height: RecordingOverlayController.height)
    }

    // MARK: Mic

    /// Lights up in the theme's colors as you talk: the ring brightens and thickens and a halo
    /// blooms around it with your voice. While thinking a comet circles it.
    private func mic(t: Double, level: Double, speaking: Double, thinking: Double, theme: OverlayTheme) -> some View {
        let colors = theme.colors
        let ring = AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(t * 40))
        let comet = AngularGradient(stops: [
            .init(color: colors[0].opacity(0), location: 0.0),
            .init(color: colors[0].opacity(0.8), location: 0.55),
            .init(color: colors[1], location: 0.85),
            .init(color: colors[2], location: 1.0),
        ], center: .center)
        let voice = pow(level, 0.7) * speaking
        return ZStack {
            Circle().fill(theme.micFill)
            Circle().strokeBorder(ring, lineWidth: 1.5 + 1.5 * voice).opacity(0.35 * speaking + 0.65 * voice + 0.2 * thinking)
            Circle()
                .trim(from: 0, to: 0.999)
                .stroke(comet, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
                .rotationEffect(.degrees(t * 300))
                .opacity(thinking)
            let ink = theme.ink.opacity(0.75 + 0.25 * level * speaking)
            Canvas { context, size in Self.drawMic(&context, size: size, color: ink) }
        }
        .frame(width: Self.micSize, height: Self.micSize)
        .background(
            Circle()
                .fill(RadialGradient(colors: [theme.accent.opacity(0.7), colors[0].opacity(0.25), colors[0].opacity(0)],
                                     center: .center, startRadius: Self.micSize * 0.3, endRadius: Self.micSize * 1.1))
                .frame(width: Self.micSize * 2.2, height: Self.micSize * 2.2)
                .scaleEffect(0.75 + 0.25 * voice)
                .opacity(voice)
        )
        .scaleEffect(1 + 0.025 * sin(t * 3.0) * thinking + 0.08 * level * speaking)
    }

    /// A mic drawn as shapes rather than the SF Symbol: a symbol is laid out like text and snapped to
    /// whole pixels, which leaves it half a pixel off the ring's center. These shapes are mirror-symmetric
    /// about the center and their outline spans 8.5...25.5 in a 34pt box, so they sit dead center.
    private static func drawMic(_ context: inout GraphicsContext, size: CGSize, color: Color) {
        let s = size.width / micSize
        let cx = size.width / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + x * s, y: y * s) }
        let head = Path(roundedRect: CGRect(x: cx - 3.5 * s, y: 8.5 * s, width: 7 * s, height: 11 * s), cornerRadius: 3.5 * s)
        context.fill(head, with: .color(color))
        var stand = Path()
        stand.addArc(center: point(0, 15.5), radius: 5.75 * s, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        stand.move(to: point(0, 21.25))
        stand.addLine(to: point(0, 24.75))
        stand.move(to: point(-3.5, 24.75))
        stand.addLine(to: point(3.5, 24.75))
        context.stroke(stand, with: .color(color), style: StrokeStyle(lineWidth: 1.5 * s, lineCap: .round))
    }

    // MARK: Bars

    private struct Bar {
        var x: CGFloat
        var length: CGFloat
        /// Position along the row, 0 at the mic to 1 at the far end.
        var along: Double
        var loudness: Double
        var color: Color
        /// How far the bubble's edge swells out above and below this bar.
        var swell: CGFloat
    }

    /// Your newest sound comes out of the mic and older sound drifts to the right.
    /// Silent, it is a calm row of dots; thinking, a pulse runs along them. The bubble swells
    /// with your voice (less near its rounded ends) and the bars grow into the room it makes.
    private static func layoutBars(t: Double, history: [Double], speaking: Double, thinking: Double,
                                   theme: OverlayTheme) -> [Bar] {
        let left = 5 + micSize + 12
        let right = barWidth - 18
        let count = barCount
        // Each bar reads the history at its own spot, between samples, so the row glides
        // a fraction of a bar every frame instead of jumping a whole bar.
        let span = Double(history.count - 1) / Double(count - 1)
        let sample = { (i: Int) -> Double in
            let at = Double(min(max(i, 0), count - 1)) * span
            let lo = Int(at), hi = min(lo + 1, history.count - 1), f = at - Double(lo)
            return history[lo] * (1 - f) + history[hi] * f
        }
        let step = (right - left) / CGFloat(count - 1)
        let resting = Double(barHeight) - 14
        let tallest = resting + 2 * Double(maxSwell)
        return (0..<count).map { i in
            let along = Double(i) / Double(count - 1)
            let room = smooth(clamp(along / 0.15)) * smooth(clamp((1 - along) / 0.2))
            // Averaged with neighbors so the outline flows instead of stepping.
            let near = (sample(i - 1) + 2 * sample(i) + sample(i + 1)) / 4
            let swell = Double(maxSwell) * room * pow(near, 0.6) * speaking
            let voice = 3 + (resting + 2 * swell - 3) * pow(sample(i), 0.85)
            let pulse = 3 + 12 * pow(max(0, sin(along * 9 - t * 7)), 4)
            let length = voice * speaking + pulse * thinking
            return Bar(x: left + CGFloat(i) * step, length: length, along: along,
                       loudness: min(1, (length - 3) / (tallest - 3)), color: theme.color(at: along), swell: swell)
        }
    }

    /// `highlight` adds a white-hot core to loud bars; on a light bubble it would wash them out.
    private static func drawBars(_ context: inout GraphicsContext, size: CGSize, bars: [Bar], highlight: Bool) {
        let mid = size.height / 2
        for bar in bars {
            var path = Path()
            path.move(to: CGPoint(x: bar.x, y: mid - bar.length / 2))
            path.addLine(to: CGPoint(x: bar.x, y: mid + bar.length / 2))
            let color = bar.color
            let fade = 1 - 0.35 * bar.along
            let style = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round) }
            context.stroke(path, with: .color(color.opacity((0.08 + 0.25 * bar.loudness) * fade)), style: style(8))
            context.stroke(path, with: .color(color.opacity(0.95 * fade)), style: style(3.8))
            if highlight, bar.loudness > 0.5 {
                context.stroke(path, with: .color(Color.white.opacity((bar.loudness - 0.5) * 1.2)), style: style(1.4))
            }
        }
    }

    // MARK: Easing

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

/// A capsule whose top and bottom edges bulge out by `edge` (x along the bar, y the swell),
/// mirrored, with the rounded ends left at rest.
private struct VoiceBubble: Shape {
    var radius: CGFloat
    var edge: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let mid = rect.midY
        let leftX = rect.minX + radius
        let rightX = rect.maxX - radius
        let points = [CGPoint(x: leftX, y: 0)] + edge.filter { $0.x > leftX && $0.x < rightX } + [CGPoint(x: rightX, y: 0)]
        var path = Path()
        path.move(to: CGPoint(x: leftX, y: mid - radius))
        Self.flow(&path, points.map { CGPoint(x: $0.x, y: mid - radius - $0.y) })
        path.addArc(center: CGPoint(x: rightX, y: mid), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        Self.flow(&path, points.reversed().map { CGPoint(x: $0.x, y: mid + radius + $0.y) })
        path.addArc(center: CGPoint(x: leftX, y: mid), radius: radius, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// A smooth line through `points`, from the current point to the last one.
    private static func flow(_ path: inout Path, _ points: [CGPoint]) {
        guard points.count > 2 else { points.last.map { path.addLine(to: $0) }; return }
        for i in 1..<points.count - 1 {
            let next = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: next, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
    }
}

// MARK: - Debug render

extension RecordingOverlayController {
    /// Draws one frame offscreen to a PNG over a plain backdrop.
    /// `open-wispr render-overlay <path> [thinking] [dark] [quiet|loud]`.
    static func renderPNG(to path: String, thinking: Bool, dark: Bool, level: Double, time: Double,
                          theme: OverlayTheme = .white) {
        let model = RecordingOverlayModel()
        model.theme = theme
        model.phase = thinking ? .thinking : .recording
        model.level = level
        var samples: [Double] = []
        for i in 0..<RecordingOverlayModel.historyLength {
            let wave: Double = 0.55 + 0.45 * sin(Double(i) * 0.34 + 1)
            let fade: Double = exp(-Double(i) * 0.011)
            samples.append(level * wave * fade)
        }
        model.history = samples
        model.appearedAt = 0
        model.phaseChangedAt = 0
        let view = RecordingOverlayView(model: model, fixedTime: time)
            .background(dark ? Color(red: 0.11, green: 0.11, blue: 0.13) : Color(red: 0.93, green: 0.93, blue: 0.95))
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: Self.width, height: Self.height)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
