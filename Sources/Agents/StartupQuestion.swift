import Foundation

/// Questions an agent asks before its prompt is usable: "do you trust this folder?" and numbered menus ("New MCP server
/// found…", "❯ 1. Yes"). Their default is usually "Yes", so whatever types into the agent — a launch prompt, the hidden
/// usage probe — must not press Enter while one is on screen. `screen`: the recent output, escapes stripped.
public enum StartupQuestion {
    private static let trust = try? NSRegularExpression(pattern: AgentManifest.trust.pattern)

    /// A menu as tmux draws it: cursor moves, not line ends, between its options, so they arrive as one line.
    public static func optionsOnLines(_ screen: String) -> String {
        screen.replacing(/\s(?=\d{1,2}\.\s)/, with: "\n")
    }

    /// The trust question's words are there.
    public static func trustAsked(_ screen: String) -> Bool {
        trust?.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) != nil
    }

    /// A numbered menu with its cursor on screen. The input box's own "❯" is followed by text, not "1.", and once a menu
    /// is answered the newer cursor is the input box's.
    public static func menuOpen(_ screen: String) -> Bool {
        guard let option = AgentManifest.AutoAnswer.optionAtCursor(screen) else { return false }
        return option.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }
}
