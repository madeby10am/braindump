import AppKit

/// Which formatting style to use in which app: Claude Prompt where you talk to AI or code,
/// Slack in Slack, Email in mail apps. Your own choices (Config.appStyles) override these.
public enum AppStyles {
    /// "default" as a style means "use the style picked in the menu".
    public static let useDefault = "default"

    public static let builtIn: [(bundleID: String, name: String, style: String)] = [
        ("com.anthropic.claudefordesktop", "Claude", "claude"),
        ("com.openai.chat", "ChatGPT", "claude"),
        ("com.apple.Terminal", "Terminal", "claude"),
        ("com.googlecode.iterm2", "iTerm", "claude"),
        ("dev.warp.Warp-Stable", "Warp", "claude"),
        ("com.mitchellh.ghostty", "Ghostty", "claude"),
        ("com.todesktop.230313mzl4w4u92", "Cursor", "claude"),
        ("com.microsoft.VSCode", "VS Code", "claude"),
        ("com.tinyspeck.slackmacgap", "Slack", "slack"),
        ("com.apple.mail", "Mail", "email"),
        ("com.microsoft.Outlook", "Outlook", "email"),
        ("com.superhuman.electron", "Superhuman", "email"),
    ]

    /// The rules to show: built-in ones for apps on this Mac, with your changes applied, then apps you added.
    public static func rules(overrides: [String: String]) -> [(bundleID: String, name: String, style: String)] {
        var out = builtIn
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map { (bundleID: $0.bundleID, name: $0.name, style: overrides[$0.bundleID] ?? $0.style) }
        let known = Set(builtIn.map(\.bundleID))
        for (bundleID, style) in overrides.sorted(by: { $0.key < $1.key }) where !known.contains(bundleID) {
            out.append((bundleID: bundleID, name: appName(bundleID), style: style))
        }
        return out
    }

    /// The style id for this app, or nil to use the style picked in the menu.
    public static func style(for bundleID: String?, overrides: [String: String]) -> String? {
        guard let bundleID else { return nil }
        let style = overrides[bundleID] ?? builtIn.first { $0.bundleID == bundleID }?.style
        return style == useDefault ? nil : style
    }

    public static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
