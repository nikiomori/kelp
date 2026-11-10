import AppKit

/// Copy and paste between the Mac and a macOS machine as its window comes and goes: what the Mac copied goes in as the
/// user clicks into the window, what the machine copied comes out as they leave it (a sign-in link for the Mac's
/// browser, its code back). Text only, over `<name>-own`: Virtualization shares no clipboard with a macOS guest.
@MainActor
enum Clipboard {
    /// The Mac's pasteboard as last handed over (its changeCount), and the machine's text as last seen.
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
            // Nothing new from the Mac: what the machine holds now is old news, not something to bring out.
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

    /// What the machine copied last, or nil when it couldn't be read (logged).
    private func guestText() async -> String? {
        do { return try await own(Self.utf8 + "pbpaste") } catch {
            log("clipboard out: \(error.localizedDescription)")
            return nil
        }
    }

    /// pbcopy and pbpaste read and write UTF-8 only under a UTF-8 locale (an ssh command gets none).
    private static let utf8 = "LANG=en_US.UTF-8 "
}
