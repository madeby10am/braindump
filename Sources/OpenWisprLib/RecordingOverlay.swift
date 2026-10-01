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

// MARK: - Model

/// What the overlay is showing right now.
final class RecordingOverlayModel: ObservableObject {
    enum Phase { case recording, thinking }

    @Published var phase: Phase = .recording
    /// Smoothed microphone loudness, 0...1, while recording.
    @Published var level: Double = 0
    /// Recent loudness, newest first (about a second at 30 samples a second).
    @Published var history: [Double] = Array(repeating: 0, count: RecordingOverlayModel.historyLength)
    static let historyLength = 25
    /// Reference-date seconds, so the view can ease between looks.
    @Published var phaseChangedAt: Double = 0
    @Published var appearedAt: Double = 0
    /// False while the panel is hidden, so the animation clock stops.
    @Published var isActive = false
}

// MARK: - Controller

/// A click-through panel near the top of the screen. While you talk the brain
/// crackles with electricity that follows your voice; while BrainDump works out
/// what you said it glows and circles ("thinking"). It never takes focus.
final class RecordingOverlayController {
    static let size: CGFloat = 300
    /// Distance from the top of the usable screen to the center of the brain.
    private static let edgeInset: CGFloat = 118

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
    /// Current microphone peak, 0...1.
    var levelProvider: () -> Float = { 0 }

    init() {
        let size = NSSize(width: Self.size, height: Self.size)
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

    /// Follows the menu-bar icon's state: recording shows the electricity,
    /// transcribing shows the thinking glow, anything else hides it.
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
        let size = Self.size
        let inset = Self.edgeInset
        let centerX: CGFloat
        switch position.column {
        case -1: centerX = usable.minX + inset
        case 1: centerX = usable.maxX - inset
        default: centerX = usable.midX
        }
        let centerY: CGFloat
        switch position.row {
        case -1: centerY = usable.maxY - inset
        case 1: centerY = usable.minY + inset
        default: centerY = usable.midY
        }
        panel.setFrame(NSRect(x: centerX - size / 2, y: centerY - size / 2, width: size, height: size), display: false)
    }

    // MARK: Voice level

    private func updateLevelTimer() {
        if visible, model.phase == .recording {
            guard levelTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tickLevel() }
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
        // Jump up with the voice, fall back a little slower.
        smoothed = raw > smoothed ? smoothed * 0.3 + raw * 0.7 : smoothed * 0.82 + raw * 0.18
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

struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel
    /// Freezes the animation at one moment, for screenshots.
    var fixedTime: Double?

    /// The icon art has a margin; the rounded square itself is ~80% of this.
    private static let iconFrame: CGFloat = 100
    private static let iconHalf: Double = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isActive && fixedTime == nil)) { timeline in
            let t = fixedTime ?? timeline.date.timeIntervalSinceReferenceDate
            let appear = Self.easeOutBack(Self.clamp((t - model.appearedAt) / 0.4))
            let blend = Self.smooth(Self.clamp((t - model.phaseChangedAt) / 0.5))
            let electric = model.phase == .recording ? blend : 1 - blend
            let thinking = 1 - electric
            let level = model.level
            let history = model.history

            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    Self.drawAura(&context, center: center, t: t, level: level, electric: electric, thinking: thinking)
                    Self.drawThinking(&context, center: center, t: t, weight: thinking)
                    Self.drawVoiceRing(&context, center: center, t: t, history: history, weight: electric)
                    Self.drawElectric(&context, center: center, t: t, level: level, history: history, weight: electric)
                }
                badge(t: t, level: level, electric: electric)
            }
            .scaleEffect(0.65 + 0.35 * appear)
            .opacity(min(1, appear * 1.5))
        }
        .frame(width: RecordingOverlayController.size, height: RecordingOverlayController.size)
    }

    // MARK: Badge

    private func badge(t: Double, level: Double, electric: Double) -> some View {
        let pulse = 1 + 0.025 * sin(t * 3.0) + 0.11 * level * electric
        return ZStack {
            Image(nsImage: SettingsView.appIcon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconFrame, height: Self.iconFrame)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .shadow(color: Self.glowRose.opacity(0.9 * level * electric), radius: 6 + 22 * level)
        }
        .scaleEffect(pulse)
    }

    // MARK: Drawing

    private static let glowViolet = Color(red: 0.62, green: 0.42, blue: 1.0)
    private static let glowRose = Color(red: 1.0, green: 0.32, blue: 0.58)
    private static let glowOrange = Color(red: 1.0, green: 0.60, blue: 0.22)
    private static var palette: [Color] { [glowViolet, glowRose, glowOrange] }

    /// Soft colored light behind the brain, in the icon's three colors.
    private static func drawAura(_ context: inout GraphicsContext, center c: CGPoint, t: Double, level: Double, electric: Double, thinking: Double) {
        let breathe = 0.5 + 0.5 * sin(t * 2.2)
        let strength = electric * (0.12 + 0.85 * level) + thinking * (0.36 + 0.3 * breathe)
        guard strength > 0.01 else { return }
        for (i, color) in palette.enumerated() {
            let angle = t * 0.9 + Double(i) * 2.0944
            let origin = CGPoint(x: c.x + cos(angle) * 20, y: c.y + sin(angle) * 20)
            let radius = 90 + 30 * level * electric + 8 * breathe * thinking
            let rect = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.6 * strength), color.opacity(0.0)]),
                    center: origin, startRadius: 8, endRadius: radius
                )
            )
        }
    }

    private static let ringBars = 48
    private static let ringRadius: Double = 58

    /// Colors of the icon around the ring: violet at the top, through rose, to orange at the bottom.
    private static func ringColor(_ x: Double) -> Color {
        let m = 1 - abs(2 * x - 1)
        let (a, b, f): ((Double, Double, Double), (Double, Double, Double), Double) = m < 0.5
            ? ((0.62, 0.42, 1.0), (1.0, 0.32, 0.58), m * 2)
            : ((1.0, 0.32, 0.58), (1.0, 0.60, 0.22), (m - 0.5) * 2)
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    /// How far a ring bar reaches. The newest sound is at the top and older
    /// sound spreads down both sides, so speech ripples around the brain.
    private static func barLength(_ i: Int, history: [Double]) -> Double {
        let d = min(i, ringBars - i)
        let v = history[min(d, history.count - 1)]
        return 3 + 36 * pow(v, 0.85)
    }

    /// A ring of bars that dance with your voice. Silent, it is a calm ring of dots.
    private static func drawVoiceRing(_ context: inout GraphicsContext, center c: CGPoint, t: Double, history: [Double], weight: Double) {
        guard weight > 0.01 else { return }
        let layer = context
        let track = Path(ellipseIn: CGRect(x: c.x - ringRadius, y: c.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        layer.stroke(track, with: .color(glowViolet.opacity(0.22 * weight)), lineWidth: 1.5)

        for i in 0..<ringBars {
            let x = Double(i) / Double(ringBars)
            let angle = x * 2 * .pi - .pi / 2
            let length = barLength(i, history: history)
            let loudness = min(1, (length - 3) / 36)
            var path = Path()
            path.move(to: CGPoint(x: c.x + cos(angle) * ringRadius, y: c.y + sin(angle) * ringRadius))
            path.addLine(to: CGPoint(x: c.x + cos(angle) * (ringRadius + length), y: c.y + sin(angle) * (ringRadius + length)))
            let color = ringColor(x)
            let style = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round) }
            layer.stroke(path, with: .color(color.opacity((0.10 + 0.22 * loudness) * weight)), style: style(8))
            layer.stroke(path, with: .color(color.opacity(0.95 * weight)), style: style(3.2))
            if loudness > 0.5 {
                layer.stroke(path, with: .color(Color.white.opacity((loudness - 0.5) * 1.4 * weight)), style: style(1.2))
            }
        }
    }

    /// Electricity that your voice feeds. Nothing happens in silence; the louder
    /// you speak, the more bolts leap from the tips of the bars, and the longer they run.
    private static func drawElectric(_ context: inout GraphicsContext, center c: CGPoint, t: Double, level: Double, history: [Double], weight: Double) {
        guard weight > 0.01, level > 0.06 else { return }
        let layer = context
        let slots = 10

        for i in 0..<slots {
            let rate = 10.0 + Double(i % 4) * 3.0
            var rng = SeededRandom(Int(t * rate) + i * 101, i)
            // Louder voice lights up more of the slots.
            if level * Double(slots) < Double(i) + rng.next() * 0.9 { continue }

            let angle = Double(i) / Double(slots) * 2 * .pi + (rng.next() - 0.5) * 0.4 + t * 0.15
            let bar = Int((angle + .pi / 2) / (2 * .pi) * Double(ringBars)) % ringBars
            let reach = ringRadius + barLength((bar + ringBars) % ringBars, history: history)
            let start = CGPoint(x: c.x + cos(angle) * reach, y: c.y + sin(angle) * reach)
            let length = (10 + 34 * rng.next()) * (0.5 + 0.9 * level)
            let main = bolt(from: start, angle: angle, length: length, segments: 6, jitter: 4 + 8 * level, rng: &rng)

            var path = Path()
            path.addLines(main)
            if rng.next() < 0.4 {
                let fork = bolt(from: main[3], angle: angle + (rng.next() < 0.5 ? -0.65 : 0.65), length: length * 0.4,
                                segments: 3, jitter: 4, rng: &rng)
                path.addLines(fork)
            }

            let tint = palette[i % palette.count]
            let style = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
            layer.stroke(path, with: .color(tint.opacity(0.16 * weight)), style: style(10))
            layer.stroke(path, with: .color(tint.opacity(0.95 * weight)), style: style(2.8))
            layer.stroke(path, with: .color(Color.white.opacity(0.95 * weight)), style: style(1.1))
            if let tip = main.last {
                let spark = CGRect(x: tip.x - 2.2, y: tip.y - 2.2, width: 4.4, height: 4.4)
                layer.fill(Path(ellipseIn: spark), with: .color(Color.white.opacity(0.9 * weight)))
            }
        }
    }

    /// A glowing comet running around the brain, with small lights orbiting it.
    private static func drawThinking(_ context: inout GraphicsContext, center c: CGPoint, t: Double, weight: Double) {
        guard weight > 0.01 else { return }
        let layer = context

        let radius: CGFloat = 60
        let ring = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))

        // Faint full ring so the path is visible.
        layer.stroke(ring, with: .color(glowViolet.opacity(0.22 * weight)), lineWidth: 1.5)

        // The comet: transparent tail fading up to a bright orange head.
        let comet = Gradient(stops: [
            .init(color: glowViolet.opacity(0), location: 0.0),
            .init(color: glowViolet.opacity(0), location: 0.45),
            .init(color: glowViolet.opacity(0.7), location: 0.7),
            .init(color: glowRose.opacity(0.95), location: 0.9),
            .init(color: glowOrange, location: 1.0),
        ])
        let hot = Gradient(stops: [
            .init(color: Color.white.opacity(0), location: 0.0),
            .init(color: Color.white.opacity(0), location: 0.88),
            .init(color: Color.white, location: 1.0),
        ])
        let spin = Angle.degrees(t * 150)
        for (width, alpha) in [(14.0, 0.12), (8.0, 0.22), (3.4, 1.0)] {
            var pass = layer
            pass.opacity = alpha * weight
            pass.stroke(ring, with: .conicGradient(comet, center: c, angle: spin), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        var core = layer
        core.opacity = weight
        core.stroke(ring, with: .conicGradient(hot, center: c, angle: spin), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

        // Little lights drifting around at different speeds, with short tails.
        for i in 0..<6 {
            let direction: Double = i % 2 == 0 ? 1 : -1
            let speed = 0.8 + Double(i) * 0.23
            let orbit = 72 + 9 * sin(t * 1.3 + Double(i) * 1.7)
            let head = Double(i) * 1.05 + t * speed * direction
            let tint = palette[i % palette.count]
            for k in 0..<9 {
                let angle = head - Double(k) * 0.075 * direction
                let fade = pow(1 - Double(k) / 9, 2)
                let size = 3.6 - Double(k) * 0.3
                let point = CGPoint(x: c.x + cos(angle) * orbit, y: c.y + sin(angle) * orbit)
                let dot = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                layer.fill(Path(ellipseIn: dot), with: .color(tint.opacity(0.9 * fade * weight)))
            }
        }
    }

    // MARK: Geometry and easing

    /// A point just outside the icon's rounded square, in the given direction.
    private static func edgePoint(center c: CGPoint, angle: Double, extra: Double) -> CGPoint {
        let n = 5.0   // squircle exponent
        let radius = iconHalf / pow(pow(abs(cos(angle)), n) + pow(abs(sin(angle)), n), 1 / n) + extra
        return CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
    }

    /// A jagged line leaving `start` along `angle`.
    private static func bolt(from start: CGPoint, angle: Double, length: Double, segments: Int, jitter: Double, rng: inout SeededRandom) -> [CGPoint] {
        let dx = cos(angle), dy = sin(angle)
        var points = [start]
        for j in 1...segments {
            let f = Double(j) / Double(segments)
            let side = (rng.next() - 0.5) * 2 * jitter * (j == segments ? 0.4 : 1)
            points.append(CGPoint(x: start.x + dx * length * f - dy * side, y: start.y + dy * length * f + dx * side))
        }
        return points
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

/// Tiny deterministic random numbers, so a bolt keeps its shape for a few
/// frames and then jumps, which is what makes it look like it's buzzing.
private struct SeededRandom {
    private var state: UInt64

    init(_ a: Int, _ b: Int) {
        state = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

// MARK: - Debug render

extension RecordingOverlayController {
    /// Draws one frame offscreen to a PNG over a plain backdrop.
    /// `open-wispr render-overlay <path> [thinking] [dark] [quiet|loud]`.
    static func renderPNG(to path: String, thinking: Bool, dark: Bool, level: Double, time: Double) {
        let model = RecordingOverlayModel()
        model.phase = thinking ? .thinking : .recording
        model.level = level
        var samples: [Double] = []
        for i in 0..<RecordingOverlayModel.historyLength {
            let wave: Double = 0.55 + 0.45 * sin(Double(i) * 0.9 + 1)
            let fade: Double = exp(-Double(i) * 0.03)
            samples.append(level * wave * fade)
        }
        model.history = samples
        model.appearedAt = 0
        model.phaseChangedAt = 0
        let view = RecordingOverlayView(model: model, fixedTime: time)
            .background(dark ? Color(red: 0.11, green: 0.11, blue: 0.13) : Color(red: 0.93, green: 0.93, blue: 0.95))
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: Self.size, height: Self.size)
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
