import AppKit
import GhosttyKit

/// The clipboard as Ghostty asks for it: a paste, and a program reading or writing it.
extension GhosttyTerminalView {
    /// Each MIME type asked for that the clipboard has ("text/plain" for a paste), and with `list` the types it offers:
    /// a program that took paste events (mode 5522) gets that listing on ⌘V and reads the type it wants.
    func readClipboard(
        state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        let pb = NSPasteboard.general
        var asked: [String] = []
        for i in 0..<count { if let m = mimes?[i].map({ String(cString: $0) }), !asked.contains(m) { asked.append(m) } }
        let contents = asked.compactMap { m in TerminalPaste.data(pb, mime: m).map { (mime: m, data: $0) } }
        guard !contents.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents, available: list ? TerminalPaste.mimes(pb) : [], state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty copies what it's handed before it returns; the bytes go with their length (a NUL in text or a PNG).
    private func complete(_ surface: ghostty_surface_t, _ contents: [(mime: String, data: Data)], available: [String], state: UnsafeMutableRawPointer?) {
        var owned: [UnsafeMutableRawPointer] = []
        defer { owned.forEach { free($0) } }
        func keep(_ d: Data) -> UnsafePointer<CChar>? {
            guard let p = malloc(d.count + 1) else { return nil }
            owned.append(p)
            d.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: d.count)
            p.storeBytes(of: 0, toByteOffset: d.count, as: UInt8.self)   // ends a MIME type as a C string
            return UnsafePointer(p.assumingMemoryBound(to: CChar.self))
        }
        let reps = contents.map { ghostty_clipboard_content_s(mime: keep(Data($0.mime.utf8)), data: keep($0.data), len: $0.data.count) }
        let names = available.map { keep(Data($0.utf8)) }
        reps.withUnsafeBufferPointer { r in
            names.withUnsafeBufferPointer { n in
                var done = ghostty_clipboard_complete_s()
                // Not confirmed: Ghostty applies its policy (`clipboard-read = ask` for OSC 52 / Kitty reads, paste
                // protection) and asks `confirmClipboard`.
                done.contents = r.baseAddress; done.contents_len = r.count
                done.available = n.baseAddress; done.available_len = n.count; done.confirmed = false
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    /// Ghostty asks before a paste that would run as typed (a line break, no bracketed paste) and before a program reads
    /// the clipboard or writes it the Kitty way. The paste goes through, unless a program put that text there: lines you
    /// never saw mustn't run on ⌘V. The rest is refused.
    func confirmClipboard(_ c: UnsafePointer<ghostty_clipboard_confirm_s>?, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c else { ghostty_surface_deny_clipboard_request(surface, state); return }
        if GhosttyRuntime.programCopy == NSPasteboard.general.changeCount {
            ghostty_surface_deny_clipboard_request(surface, state); onPasteRefused?(); return
        }
        var done = ghostty_clipboard_complete_s()
        done.contents = c.pointee.contents; done.contents_len = c.pointee.contents_len; done.confirmed = true
        ghostty_surface_complete_clipboard_request(surface, &done, state)
    }
}
