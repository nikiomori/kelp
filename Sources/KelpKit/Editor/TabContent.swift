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
    /// The marks of a session (an agent or a terminal), shown on its tab and around its pane. A tab that has them is a
    /// terminal, so it fades a little in an unfocused split, as in Ghostty.
    var badge: TabBadge? { get }
    var toolTip: String? { get }
    /// Unsaved changes: the tab shows a dot, closing it asks first.
    var isEdited: Bool { get }
    func focus()
    /// Return false to keep the tab (e.g. the user cancelled). Questions are sheets, awaited.
    func close() async -> Bool

    // What the shell asks of a tab without knowing its kind (built-ins answer; the defaults say "not this one").
    /// The columns × rows of the terminal on screen, used to size the next terminal before it's shown.
    var terminalGrid: (cols: Int, rows: Int)? { get }
    /// The file the tab shows (for Reveal in Finder).
    var fileURL: URL? { get }
    /// The tab's language, when ⌘R / ⌘U can run it without a project command.
    var language: LanguageSpec? { get }
    /// The command that runs it ("run") or its test at the cursor ("test"); nil when there is none.
    func command(_ name: String) async -> String?
    /// Shows that line (for a link to a file that's already open at another line).
    func goTo(line: Int)
}

/// What a tab shows of itself. Its parts are observed state (`@Observable` tabs, or the app's models they read), and
/// the shell follows them with `track`, so a tab doesn't have to report a change.
struct TabLook: Equatable {
    let uri: String, title: String, toolTip: String?, isEdited: Bool, badge: TabBadge?, icon: NSImage?
    @MainActor init(_ tabContent: TabContent) {
        uri = tabContent.uri
        title = tabContent.title
        toolTip = tabContent.toolTip
        isEdited = tabContent.isEdited
        badge = tabContent.badge
        icon = tabContent.icon
    }
}

/// What a session's tab shows besides its title, and the ring around its pane.
package struct TabBadge: Equatable {
    init(
        status: AgentStatus? = nil,
        unread: Bool = false,
        meter: SessionContextWindow.Usage? = nil,
        progress: Double? = nil,
        attention: NSColor? = nil,
        backgroundOf session: Session? = nil
    ) {
        self.status = status
        self.unread = unread
        self.meter = meter
        self.progress = progress
        self.attention = attention
        background = session?.aside.count ?? 0
        backgroundTip = session?.backgroundTip
        waitsFor = session?.waitsForCommand ?? false
        guessed = session?.guessed == true
        limited = session?.limitHit != nil
        compacting = session?.compacting ?? false
    }
    /// Makes the badge of a session's tab, built or not (a hidden terminal lets go of its surface, and its tab still
    /// shows all of this).
    package static func of(_ session: Session?, meter: SessionContextWindow.Usage?) -> TabBadge {
        // A terminal shows a state only while a program in it says how far it got (a build).
        TabBadge(
            status: session.flatMap {
                $0.isTerminal
                    ? ($0.progress == nil ? nil : .working) : $0.endedWithError ? .error : $0.markStatus
            },
            unread: session?.unread ?? false, meter: meter, progress: session?.progress.map { Double($0) / 100 },
            attention: session.flatMap(attention),
            backgroundOf: session)
    }
    /// The ring around the session's pane: orange when it asks, red when it failed and is unread. Finished is quiet, as
    /// its mark in the sidebar is, because the unread dot and the bold name say it's new.
    private static func attention(_ session: Session) -> NSColor? {
        guard !session.isTerminal else { return nil }
        if session.status == .waiting { return .systemOrange }
        return (session.status == .error || session.endedWithError) && session.unread ? .systemRed : nil
    }

    /// The state mark (nil for a terminal whose program doesn't say how far it got).
    var status: AgentStatus?
    /// Finished and not looked at yet (the filled ✓).
    var unread = false
    /// How full an agent's conversation is; the tab shows a ring once answers may start to slip (`ContextMeter.level`).
    var meter: SessionContextWindow.Usage?
    /// How far the program running in the session got (0…1), when it says; the status mark fills to match.
    var progress: Double?
    /// The coloured ring around the pane: an agent asking (orange), or one that failed and is unread (red).
    var attention: NSColor?
    /// How many commands run beside the agent, whatever it's doing (`Session.aside`), and their names in
    /// `backgroundTip`.
    var background = 0
    var backgroundTip: String?
    /// The agent works on only to see its command end, so its mark is the ring of dots.
    var waitsFor = false
    /// The other ways the mark tells work apart, as in the chat's row: a status read off the screen (dashes), a plan
    /// limit that stopped it (a clock), its conversation being compacted (a pulse).
    var guessed = false, limited = false, compacting = false
}

/// A tab holding work that can be unsaved: ⌘S, Save All and quitting save it.
@MainActor
package protocol SavableTab: TabContent {
    /// Returns false when nothing was written (the user cancelled, or the save failed and said why).
    @discardableResult func save() async -> Bool
    /// Called when the user chose Don't Save for a tab that's going away. The tab isn't edited any more, and nothing
    /// writes it later.
    func discard()
    /// A save still on its way (a remote file's, to its host), which closing or quitting waits for.
    var pendingSave: Task<Void, Never>? { get }
    /// The URI that brings the tab back once closed: a file at the line it was on. Nil when nothing can (an untitled
    /// text).
    var reopenURI: String? { get }
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
