import AppKit

/// What ⌘-click would open under the pointer, said while ⌘ is held (`onLinkHover`).
extension GhosttyTerminalView {
    /// Ghostty's link under the pointer changed ("" off one).
    func overLink(_ url: String) {
        ghosttyLink = url
        refreshLink()
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
                // The app looks for files: once a word.
                if lastWord?.texts != hit.texts { lastWord = (hit.texts, onPathAt?(hit.texts)) }
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
