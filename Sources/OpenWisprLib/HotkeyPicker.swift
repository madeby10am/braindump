import SwiftUI

/// A clickable Mac keyboard for choosing the dictation hotkey, plus the
/// hold / toggle / auto-stop mode picker.
struct KeyDef: Identifiable {
    let label: String
    let name: String
    let code: UInt16
    let width: CGFloat
    var id: String { name }

    /// Modifier keys work alone as a hotkey without breaking typing.
    var isModifier: Bool { KeyDef.modifierCodes.contains(code) }

    static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(_ label: String, _ name: String, _ code: UInt16, _ width: CGFloat = 1) {
        self.label = label
        self.name = name
        self.code = code
        self.width = width
    }
}

enum MacKeyboard {
    static let rows: [[KeyDef]] = [
        [KeyDef("esc", "Escape", 53), KeyDef("F1", "F1", 122), KeyDef("F2", "F2", 120), KeyDef("F3", "F3", 99),
         KeyDef("F4", "F4", 118), KeyDef("F5", "F5", 96), KeyDef("F6", "F6", 97), KeyDef("F7", "F7", 98),
         KeyDef("F8", "F8", 100), KeyDef("F9", "F9", 101), KeyDef("F10", "F10", 109), KeyDef("F11", "F11", 103),
         KeyDef("F12", "F12", 111), KeyDef("F13", "F13", 105, 1.5)],
        [KeyDef("`", "`", 50), KeyDef("1", "1", 18), KeyDef("2", "2", 19), KeyDef("3", "3", 20), KeyDef("4", "4", 21),
         KeyDef("5", "5", 23), KeyDef("6", "6", 22), KeyDef("7", "7", 26), KeyDef("8", "8", 28), KeyDef("9", "9", 25),
         KeyDef("0", "0", 29), KeyDef("-", "-", 27), KeyDef("=", "=", 24), KeyDef("delete", "Delete", 51, 1.5)],
        [KeyDef("tab", "Tab", 48, 1.5), KeyDef("Q", "Q", 12), KeyDef("W", "W", 13), KeyDef("E", "E", 14), KeyDef("R", "R", 15),
         KeyDef("T", "T", 17), KeyDef("Y", "Y", 16), KeyDef("U", "U", 32), KeyDef("I", "I", 34), KeyDef("O", "O", 31),
         KeyDef("P", "P", 35), KeyDef("[", "[", 33), KeyDef("]", "]", 30), KeyDef("\\", "\\", 42)],
        [KeyDef("caps", "Caps Lock", 57, 1.75), KeyDef("A", "A", 0), KeyDef("S", "S", 1), KeyDef("D", "D", 2), KeyDef("F", "F", 3),
         KeyDef("G", "G", 5), KeyDef("H", "H", 4), KeyDef("J", "J", 38), KeyDef("K", "K", 40), KeyDef("L", "L", 37),
         KeyDef(";", ";", 41), KeyDef("'", "'", 39), KeyDef("return", "Return", 36, 1.75)],
        [KeyDef("⇧ shift", "Left Shift", 56, 2.25), KeyDef("Z", "Z", 6), KeyDef("X", "X", 7), KeyDef("C", "C", 8), KeyDef("V", "V", 9),
         KeyDef("B", "B", 11), KeyDef("N", "N", 45), KeyDef("M", "M", 46), KeyDef(",", ",", 43), KeyDef(".", ".", 47),
         KeyDef("/", "/", 44), KeyDef("shift ⇧", "Right Shift", 60, 2.25)],
        [KeyDef("fn 🌐", "Fn / Globe", 63), KeyDef("⌃ ctrl", "Left Control", 59), KeyDef("⌥ opt", "Left Option", 58),
         KeyDef("⌘ cmd", "Left Command", 55, 1.25), KeyDef("space", "Space", 49, 5), KeyDef("⌘ cmd", "Right Command", 54, 1.25),
         KeyDef("⌥ opt", "Right Option", 61), KeyDef("⌃ ctrl", "Right Control", 62, 2.75)],
    ]

    static func key(for code: UInt16) -> KeyDef? {
        for row in rows { if let k = row.first(where: { $0.code == code }) { return k } }
        return nil
    }

    static let modifierSymbols: [(name: String, symbol: String)] = [
        ("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘"),
    ]

    static func normalized(_ mod: String) -> String {
        switch mod.lowercased() {
        case "cmd", "command": return "cmd"
        case "shift": return "shift"
        case "ctrl", "control": return "ctrl"
        case "opt", "option", "alt": return "opt"
        default: return mod.lowercased()
        }
    }

    /// "⌃⌥ Space", "Left Option", "Fn / Globe".
    static func describe(code: UInt16, modifiers: [String]) -> String {
        let keyName = key(for: code)?.name ?? (KeyCodes.codeToName[code] ?? "Key \(code)")
        let mods = Set(modifiers.map(normalized))
        let prefix = modifierSymbols.filter { mods.contains($0.name) }.map(\.symbol).joined()
        return prefix.isEmpty ? keyName : "\(prefix) \(keyName)"
    }
}

struct HotkeyPickerView: View {
    @ObservedObject var model: SettingsModel
    @State private var pendingMods: Set<String> = []

    private let unit: CGFloat = 34
    private let gap: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How the hotkey works").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(Config.HotkeyMode.allCases, id: \.self) { mode in
                        ModeCard(mode: mode, selected: model.hotkeyMode == mode) {
                            model.setHotkeyMode(mode)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pick a key").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Current: \(model.hotkey)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("Combine with:").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(MacKeyboard.modifierSymbols, id: \.name) { m in
                        let on = pendingMods.contains(m.name)
                        Button {
                            if on { pendingMods.remove(m.name) } else { pendingMods.insert(m.name) }
                        } label: {
                            Text(m.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.accent : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("then click a key. Modifier keys work on their own.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(MacKeyboard.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: gap) {
                            ForEach(row) { key in
                                KeyCap(
                                    key: key,
                                    width: key.width * unit + (key.width - 1) * gap,
                                    height: unit,
                                    selected: key.code == model.hotkeyCode
                                ) {
                                    model.setHotkey(code: key.code, modifiers: key.isModifier ? [] : Array(pendingMods))
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))

                if let warning = model.hotkeyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(20)
        .onAppear { pendingMods = Set(model.hotkeyMods.map(MacKeyboard.normalized)) }
    }
}

private struct ModeCard: View {
    let mode: Config.HotkeyMode
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch mode {
        case .hold: return "hand.point.down"
        case .toggle: return "switch.2"
        case .auto: return "waveform.badge.mic"
        }
    }

    private var detail: String {
        switch mode {
        case .hold: return "Hold the key while you talk, let go to paste."
        case .toggle: return "Tap to start, tap again to stop."
        case .auto: return "Tap once and talk. Stops when you go quiet."
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    Text(Config.modeLabel(mode)).font(.system(size: 12, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct KeyCap: View {
    let key: KeyDef
    let width: CGFloat
    let height: CGFloat
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(key.label)
                .font(.system(size: key.label.count > 2 ? 10 : 12, weight: .medium))
                .foregroundStyle(selected ? .white : .primary)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.86, green: 0.15, blue: 0.47)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                        .shadow(color: .black.opacity(0.12), radius: 0, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(hovering && !selected ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(key.name)
    }
}
