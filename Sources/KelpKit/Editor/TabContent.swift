import AppKit
import Core
import WorkbenchKit

/// Anything shown as a tab in the editor area. Made by a `TabProvider` from a URI.
@MainActor
package protocol TabContent: AnyObject {
    var view: NSView { get }
    var uri: String { get }
    var title: String { get }
    var icon: NSImage? { get }
    /// A session's (an agent's or a terminal's) marks, on its tab and around its pane. A tab with one is a terminal: it
    /// fades a little in an unfocused split, like Ghostty's.
    var badge: TabBadge? { get }
    var toolTip: String? { get }
    /// Unsaved changes: the tab shows a dot, closing it asks first.
    var isEdited: Bool { get }
    func focus()
    /// Return false to keep the tab (e.g. the user cancelled). Questions are sheets, awaited.
    func close() async -> Bool

    // What the shell asks of a tab without knowing its kind (built-ins answer; the defaults say "not this one").
    /// Columns × rows of the terminal on screen, which sizes the next one before it's shown.
    var terminalGrid: (cols: Int, rows: Int)? { get }
    /// The file it shows (Reveal in Finder).
    var fileURL: URL? { get }
    /// Its language, when ⌘R / ⌘U can run it without a project command.
    var language: LanguageSpec? { get }
    /// The command that runs it ("run") or its test at the cursor ("test"); nil when there is none.
    func command(_ name: String) async -> String?
    /// Shows that line (a link to a file that's already open at another line).
    func goTo(line: Int)
}

/// What a tab shows of itself. Its parts are observed state (`@Observable` tabs, or the app's models they read): the shell
/// follows them with `track`, so a tab says nothing when they change.
struct TabLook: Equatable {
    let uri: String, title: String, toolTip: String?, isEdited: Bool, badge: TabBadge?, icon: NSImage?
    @MainActor init(_ c: TabContent) {
        uri = c.uri
        title = c.title
        toolTip = c.toolTip
        isEdited = c.isEdited
        badge = c.badge
        icon = c.icon
    }
}

/// What a session's tab shows besides its title, and the ring around its pane.
package struct TabBadge: Equatable {
    package init(status: AgentStatus? = nil,
                 unread: Bool = false,
                 meter: SessionContextWindow.Usage? = nil,
                 progress: Double? = nil,
                 attention: NSColor? = nil) {
        self.status = status
        self.unread = unread
        self.meter = meter
        self.progress = progress
        self.attention = attention
    }
    /// Its state mark (nil: a terminal whose program doesn't say how far it got).
    var status: AgentStatus?
    /// Finished and not looked at yet (the filled ✓).
    var unread = false
    /// How full an agent's conversation is; the tab shows a ring once answers may start to slip (`ContextMeter.level`).
    var meter: SessionContextWindow.Usage?
    /// How far what runs in it got (0…1), when it says: its status mark fills.
    var progress: Double?
    /// The colored ring around its pane: an agent asking (orange), failed (red), finished unseen (accent).
    var attention: NSColor?
}

/// A tab holding work that can be unsaved: ⌘S, Save All and quitting save it.
@MainActor
package protocol SavableTab: TabContent {
    /// False when nothing was written (the user cancelled, or it failed and said why).
    @discardableResult func save() async -> Bool
    /// The user chose Don't Save for a tab that's going away: it isn't edited any more, and nothing writes it later.
    func discard()
    /// A save still on its way (a remote file's, to its host): what closing or quitting waits for.
    var pendingSave: Task<Void, Never>? { get }
}

extension SavableTab {
    package var pendingSave: Task<Void, Never>? { nil }
}

extension TabContent {
    package var badge: TabBadge? { nil }
    package var toolTip: String? { nil }
    package var isEdited: Bool { false }
    package func close() async -> Bool { true }
    package var terminalGrid: (cols: Int, rows: Int)? { nil }
    package var fileURL: URL? { nil }
    package var language: LanguageSpec? { nil }
    package func command(_ name: String) async -> String? { nil }
    package func goTo(line: Int) {}
}

/// SF Symbol image helper used by tabs and menus; a few names get Kelp's own drawing instead (Glyph).
extension NSImage {
    package static func symbol(_ name: String, _ label: String? = nil) -> NSImage {
        if let g = Glyph.image(name) { g.accessibilityDescription = label; return g }
        return NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }
}
