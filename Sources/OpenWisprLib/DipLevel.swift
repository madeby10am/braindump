import Foundation

/// How far music and other sound is turned down while BrainDump records.
public enum DipLevel: String, CaseIterable, Identifiable {
    case light, medium, strong

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    /// Position on the 3-stop slider.
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 1 }

    public init(index: Int) {
        self = Self.allCases[min(max(index, 0), Self.allCases.count - 1)]
    }

    /// Shown on hover over "Music dipping" in the menu and in Settings.
    public static let explanation = "Turns down music and other sound from your Mac while you're recording, so your microphone doesn't pick it up and cause echo or feedback. Everything returns to normal the moment you stop. Use the slider to choose how much it dips."

    /// macOS only exposes the ducking strength from version 14.
    public static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    public static let shortExplanation = "Lowers other sound while you record to prevent feedback."
}
