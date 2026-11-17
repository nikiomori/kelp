import Foundation

/// A finished agent counts as read once its pane has been the one you're in, in the front window, for a second. That is
/// a glance, not a click. Opening a workspace in passing doesn't clear anything, and neither does a neighbouring pane.
/// This type makes the decision without the window: which sessions to mark read now. Each session is asked for once,
/// until the record says it's read or the request failed.
public struct Glances: Sendable {
    private var since: [String: Date] = [:]
    private var asked: Set<String> = []
    public init() {}

    /// Returns the sessions to mark read now. `front` says the window is the key one, in the active app, on screen.
    /// `shown` holds the sessions being looked at. `readable` says a session is finished and unread (not a question,
    /// not a failure). `unread` says the record still says unread.
    public mutating func tick(
        front: Bool, shown: [String], readable: (String) -> Bool, unread: (String) -> Bool, now: Date
    ) -> [String] {
        guard front else {
            since = [:]
            return []
        }
        asked = asked.filter(unread)   // a session marked read may finish unread again later
        let shown = Set(shown)
        since = since.filter { shown.contains($0.key) }
        var mark: [String] = []
        for id in shown.sorted() {
            guard readable(id), !asked.contains(id) else {
                since[id] = nil
                continue
            }
            let first = since[id] ?? now
            since[id] = first
            guard now.timeIntervalSince(first) >= 1 else { continue }
            since[id] = nil
            asked.insert(id)
            mark.append(id)
        }
        return mark
    }

    /// Called when marking a session read failed, so it is asked for again on a later glance.
    public mutating func failed(_ id: String) { asked.remove(id) }
}
