import AppKit

/// What ⌘-click would open under the pointer, said while ⌘ is held (`onLinkHover`).
extension GhosttyTerminalView {
    /// Ghostty's link under the pointer changed ("" off one). Ghostty says so from inside `ghostty_surface_mouse_pos`,
    /// with the surface locked, and `refreshLink` reads the screen's text (`word(at:)`), which waits for that lock: so
    /// it runs after the call returns, or ⌘ held over the terminal froze the app.
    func overLink(_ url: String) {
        ghosttyLink = url
        Task { @MainActor [weak self] in self?.refreshLink() }
    }
    /// While ⌘ is held, says what ⌘-click would open under the pointer (`onLinkHover`), and over a path the app opens
    /// gives it the hand and the underline Ghostty shows on its own links.
    func refreshLink() {
        var shown = "", under = NSRect.zero
        if NSEvent.modifierFlags.contains(.command), let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !ghosttyLink.isEmpty {
                shown = ghosttyLink
            } else if bounds.contains(point), let hit = word(at: point) {
                if lastWord?.texts != hit.texts { lookUp(hit.texts) }
                shown = lastWord?.path ?? ""
                under = NSRect(x: hit.rect.minX, y: hit.rect.minY + 1, width: hit.rect.width, height: 1)
            }
        } else {
            lastWord = nil   // a file made since is found at the next ⌘
        }
        let onPath = !shown.isEmpty && shown != ghosttyLink
        underline.isHidden = !onPath
        if onPath {
            underline.frame = under
            effectiveAppearance.performAsCurrentDrawingAppearance {
                underline.layer?.backgroundColor = NSColor.labelColor.cgColor
            }
        }
        if onPath != overPath {
            overPath = onPath
            window?.invalidateCursorRects(for: self)
        }
        guard shown != shownLink else { return }
        shownLink = shown
        onLinkHover?(shown)
    }
    /// Asks the app once a word for its path, which may take a while (it stats files): the pill and underline show when
    /// the answer comes, if ⌘ is still held over that word. `refreshLink` then runs in its own task, not inside a
    /// Ghostty callback.
    private func lookUp(_ texts: [String]) {
        lastWord = (texts, nil)
        Task { @MainActor [weak self] in
            guard let path = await self?.onPathAt?(texts), let self, lastWord?.texts == texts else { return }
            lastWord = (texts, path)   // not after the pointer moved on or ⌘ was let go (that clears lastWord)
            refreshLink()
        }
    }
    /// A click does what the pill said, so it goes until the pointer moves again: what opens may take the focus, and
    /// ⌘'s release would go to another view.
    func endLink() {
        underline.isHidden = true
        if overPath {
            overPath = false
            window?.invalidateCursorRects(for: self)
        }
        guard !shownLink.isEmpty else { return }
        shownLink = ""
        onLinkHover?("")
    }
}
