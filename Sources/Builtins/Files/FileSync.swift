import Foundation

/// What a file tab does with its buffer when it saves or sees its file change: agents edit files under open tabs,
/// and neither side's edits may be lost silently.
enum FileSync {
    /// The file on disk: gone (moved or deleted), or there with its text (nil when it isn't UTF-8).
    enum Disk: Equatable, Sendable { case missing, present(String?) }

    enum Action: Equatable, Sendable {
        case none
        /// Write the buffer.
        case write
        /// No local edits: take the disk's text.
        case follow(String)
        /// Both changed: ask (keep mine / use the disk's).
        case conflict(String)
        /// The file is gone: never write it back without asking.
        case missing
    }

    /// The same text unit for unit, as the file's bytes would be. Not `==`: the editor's text is an NSString, which Swift
    /// compares against a Swift string character by character, normalizing — 170 ms for 5 MB, on every keystroke.
    /// `buffer` first: the editor's copy compares fastest as the receiver.
    static func same(_ buffer: String, _ other: String) -> Bool {
        buffer.utf16.count == other.utf16.count && (buffer as NSString).isEqual(to: other)
    }

    /// ⌘S, autosave, closing: `saved` is what the buffer was last loaded from or written as.
    static func save(buffer: String, saved: String, disk: Disk) -> Action {
        guard !same(buffer, saved) else { return .none }
        switch disk {
        case .missing: return .missing
        case .present(let text?) where !same(text, saved): return .conflict(text)
        case .present(nil): return .conflict("")   // not readable as text: someone wrote it another way; never written over unasked
        case .present: return .write
        }
    }

    /// The file changed on disk.
    static func diskChanged(buffer: String, saved: String, disk: Disk) -> Action {
        switch disk {
        case .missing: return .missing
        case .present(let text?) where !same(text, saved): return same(buffer, saved) ? .follow(text) : .conflict(text)
        case .present(nil): return .conflict("")   // no longer text (another encoding, binary): ask, as save does
        case .present: return .none
        }
    }
}
