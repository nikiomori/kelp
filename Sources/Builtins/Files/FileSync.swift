import Foundation

/// Decides what a file tab does with its buffer when it saves or sees its file change. Agents edit files under open
/// tabs, and neither side's edits may be lost silently.
enum FileSync {
    /// The file on disk: gone (moved or deleted), or there with its text (nil when it isn't UTF-8).
    enum Disk: Equatable, Sendable { case missing, present(String?) }

    enum Action: Equatable, Sendable {
        case none
        /// Write the buffer.
        case write
        /// No local edits: take the disk's text.
        case follow(String)
        /// Both the buffer and the disk changed, so ask whether to keep the buffer or use the disk's text.
        case conflict(String)
        /// The file is gone: never write it back without asking.
        case missing
    }

    /// Returns whether two texts match UTF-16 unit for unit, as the file's bytes would. It doesn't use `==`, because
    /// the editor's text is an NSString, which Swift compares against a Swift string character by character with
    /// normalization (170 ms for 5 MB, on every keystroke). Pass `buffer` first, because the editor's copy compares
    /// fastest as the receiver.
    static func same(_ buffer: String, _ other: String) -> Bool {
        buffer.utf16.count == other.utf16.count && (buffer as NSString).isEqual(to: other)
    }

    /// Decides what a save does (⌘S, autosave, closing the tab). `saved` is the text the buffer was last loaded from or
    /// written as.
    static func save(buffer: String, saved: String, disk: Disk) -> Action {
        guard !same(buffer, saved) else { return .none }
        switch disk {
        case .missing: return .missing
        case .present(let text?) where !same(text, saved): return .conflict(text)
        case .present(nil): return .conflict("")   // not readable as text, so someone wrote it another way: ask first
        case .present: return .write
        }
    }

    /// Decides what to do when the file changed on disk.
    static func diskChanged(buffer: String, saved: String, disk: Disk) -> Action {
        switch disk {
        case .missing: return .missing
        case .present(let text?) where !same(text, saved): return same(buffer, saved) ? .follow(text) : .conflict(text)
        case .present(nil): return .conflict("")   // no longer text (another encoding, binary): ask, as save does
        case .present: return .none
        }
    }
}
