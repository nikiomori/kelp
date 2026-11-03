import Foundation

/// A finished agent counts as read once its pane has been the one you're in, in the front window, for a second: a glance,
/// not a click. Opening a workspace in passing doesn't clear anything, nor does a neighbouring pane. The decision without the window: which sessions to
/// mark read now, each asked once until the record says it's read (or the ask failed).
public struct Glances: Sendable {
    private var since: [String: Date] = [:]
    private var asked: Set<String> = []
    public init() {}

    /// `front`: the window is the key one, in the active app, on screen. `shown`: the sessions being looked at.
    /// `readable`: finished and unread (not a question, not a failure). `unread`: the record still says unread.
    public mutating func tick(front: Bool, shown: [String], readable: (String) -> Bool, unread: (String) -> Bool, now: Date) -> [String] {
        guard front else { since = [:]; return [] }
        asked = asked.filter(unread)   // heard back: it may finish unread again later
        let shown = Set(shown)
        since = since.filter { shown.contains($0.key) }
        var mark: [String] = []
        for id in shown.sorted() {
            guard readable(id), !asked.contains(id) else { since[id] = nil; continue }
            let first = since[id] ?? now
            since[id] = first
            guard now.timeIntervalSince(first) >= 1 else { continue }
            since[id] = nil
            asked.insert(id)
            mark.append(id)
        }
        return mark
    }

    /// Its mark-read failed: asked again on a later glance.
    public mutating func failed(_ id: String) { asked.remove(id) }
}
