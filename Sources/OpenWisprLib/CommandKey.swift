import Foundation

/// The key you hold for Command Mode: highlight text, hold it, say what to do ("make this shorter"),
/// let go, and the highlighted text is rewritten. With nothing highlighted, it writes what you asked for.
public enum CommandKey: String, CaseIterable, Identifiable {
    case off, rightcmd, rightctrl, rightshift

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .rightcmd: return "Right Command"
        case .rightctrl: return "Right Control"
        case .rightshift: return "Right Shift"
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .off: return nil
        case .rightcmd: return 54
        case .rightctrl: return 62
        case .rightshift: return 60
        }
    }
}
