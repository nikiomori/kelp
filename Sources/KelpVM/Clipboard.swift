import AppKit

/// Copy and paste between the Mac and a macOS machine, as the machine's window becomes key and stops being key. What
/// the Mac copied goes into the machine when the user clicks into the window. What the machine copied comes out to the
/// Mac when the user leaves the window (for example a sign-in link for the Mac's browser, and the code sent back).
/// Only text is carried, over `<name>-own`, because Virtualization shares no clipboard with a macOS guest.
@MainActor
enum Clipboard {
    /// `mac` is the changeCount of the Mac's pasteboard when it was last handed over. `guest` is the machine's
    /// clipboard text as last seen.
    static var mac = -1
    static var guest: String?
}

extension Runtime {
    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { clipboardIn() }   // AppKit posts it on the main thread
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { clipboardOut() }   // AppKit posts it on the main thread
    }

    private func clipboardIn() {
        guard machine.kind == .macos, state == .running else { return }
        let board = NSPasteboard.general
        guard board.changeCount != Clipboard.mac, let text = board.string(forType: .string) else {
            // The Mac has copied nothing new. When nothing is remembered yet, whatever the machine's clipboard holds
            // now is remembered as already seen, so leaving the window doesn't bring that old text out to the Mac.
            if Clipboard.guest == nil { Task { Clipboard.guest = await guestText() } }
            return
        }
        Clipboard.mac = board.changeCount
        Task {
            do {
                _ = try await own(Self.utf8 + "pbcopy", stdin: Data(text.utf8))
                Clipboard.guest = text
            } catch { log("clipboard in: \(error.localizedDescription)") }
        }
    }

    private func clipboardOut() {
        guard machine.kind == .macos, state == .running else { return }
        Task {
            guard let text = await guestText(), !text.isEmpty, text != Clipboard.guest else {
                return
            }
            Clipboard.guest = text
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            Clipboard.mac = board.changeCount
        }
    }

    /// Returns the text the machine copied last, or nil when it couldn't be read (the failure is logged).
    private func guestText() async -> String? {
        do { return try await own(Self.utf8 + "pbpaste") } catch {
            log("clipboard out: \(error.localizedDescription)")
            return nil
        }
    }

    /// pbcopy and pbpaste read and write UTF-8 only under a UTF-8 locale, and a command run over ssh gets no locale.
    private static let utf8 = "LANG=en_US.UTF-8 "
}
