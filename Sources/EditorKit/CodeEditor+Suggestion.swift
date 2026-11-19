import AppKit

/// Gray text after the cursor (InlineSuggestion): asked for once typing pauses, shortened as you type the same, ⇥ puts
/// it all in, ⌥→ a word, Esc or any other move drops it.
extension CodeEditor {
    /// Asks the app for a suggestion while typing pauses; nil means none are asked for.
    public var suggestionProvider: ((InlineSuggestion.Context) async -> String?)? {
        get { suggestion.provider }
        set {
            suggestion.provider = newValue
            if newValue == nil { dropSuggestion() }
        }
    }

    /// How long typing pauses before a suggestion is asked for.
    public var suggestionDelay: Duration {
        get { suggestion.delay }
        set { suggestion.delay = newValue }
    }

    /// Told when a suggestion first shows (false) and when ⇥ or ⌥→ takes some of it (true, once per suggestion).
    public var onSuggestion: ((_ taken: Bool) -> Void)? {
        get { suggestion.onEvent }
        set { suggestion.onEvent = newValue }
    }

    /// Whether gray text is showing now.
    public var isSuggesting: Bool { suggestion.shown != nil }

    /// After an edit: shortens what's shown when the edit typed its start, else drops it and asks again.
    func suggestionTextChanged() {
        suggestion.edits += 1
        if let shown = suggestion.shown {
            // The selection's news may have come first and shortened it already.
            if shown.length == textView.length, textView.selectedRange() == NSRange(location: shown.at, length: 0) {
                return
            }
            if typedThrough(shown) { return }
        }
        dropSuggestion()
        askSoon()
    }

    /// A cursor moved by hand drops the suggestion; moving over an auto-paired closer is typing, which
    /// `suggestionTextChanged` already saw.
    func suggestionSelectionChanged() {
        nextEditSelectionChanged()
        guard let shown = suggestion.shown, textView.selectedRange() != NSRange(location: shown.at, length: 0) else {
            return
        }
        if !typedThrough(shown) { dropSuggestion() }
    }

    /// Takes ⇥, ⌥→ and Esc while a suggestion shows. Returns true when it took the key.
    func handleSuggestion(_ command: Selector) -> Bool {
        guard let shown = suggestion.shown else { return false }
        switch command {
        case #selector(NSResponder.insertTab(_:)): accept(shown.text, at: shown.at)
        case #selector(NSResponder.moveWordRight(_:)): accept(InlineSuggestion.nextWord(of: shown.text), at: shown.at)
        case #selector(NSResponder.cancelOperation(_:)): dropSuggestion()
        default: return false
        }
        return true
    }

    func dropSuggestion() {
        suggestion.task?.cancel()
        suggestion.task = nil
        guard suggestion.shown != nil else { return }
        suggestion.shown = nil
        showGhost(nil)
        markBrackets()
    }

    private func typedThrough(_ shown: SuggestionState.Shown) -> Bool {
        let string = textView.string as NSString, at = textView.selectedRange()
        guard at.length == 0, at.location > shown.at, at.location <= string.length,
            string.length - shown.length == at.location - shown.at,
            let left = InlineSuggestion.remaining(
                shown.text, after: string.substring(with: NSRange(location: shown.at, length: at.location - shown.at)))
        else { return false }
        show(left, at: at.location)
        return true
    }

    /// Puts in `text`, the start of what shows: what's left of it goes on showing, as if typed (`typedThrough`).
    private func accept(_ text: String, at location: Int) {
        if !suggestion.taken {
            suggestion.taken = true
            suggestion.onEvent?(true)
        }
        textView.replace([NSRange(location: location, length: 0)], with: [text])
        textView.setSelectedRange(NSRange(location: location + (text as NSString).length, length: 0))
    }

    /// The text around the only cursor, when a suggestion may go there: no selection, nothing else going on at the
    /// cursor, and the rest of its line empty or closers.
    private var askable: (context: InlineSuggestion.Context, rest: Substring, below: String, at: Int)? {
        let tv = textView, at = tv.selectedRange()
        guard suggestion.provider != nil, tv.isEditable, tv.cursors.count == 1, at.length == 0,
            completion.list?.isOpen != true, !completion.snippetActive, !tv.hasMarkedText(),
            tv.window?.firstResponder === tv
        else { return nil }
        let string = tv.string as NSString
        let lineEnd = MultiCursor.lineEnd(string, at.location)
        let rest = string.substring(with: NSRange(location: at.location, length: lineEnd - at.location))
        guard InlineSuggestion.fits(beforeRest: Substring(rest)) else { return nil }
        let from = InlineSuggestion.windowStart(at: at.location, in: string)
        let to = InlineSuggestion.windowEnd(at: at.location, in: string)
        let context = InlineSuggestion.Context(
            prefix: string.substring(with: NSRange(location: from, length: at.location - from)),
            suffix: string.substring(with: NSRange(location: at.location, length: to - at.location)),
            languageId: languageId, path: url.path)
        return (
            context, Substring(rest), string.substring(with: NSRange(location: lineEnd, length: to - lineEnd)),
            at.location
        )
    }

    /// Once typing pauses: gray text where it may go, else (or when none comes) the next edit.
    private func askSoon() {
        let edits = suggestion.edits, delay = suggestionDelay
        guard let ask = askable, let provider = suggestion.provider else {
            guard nextEdit.provider != nil else { return }
            suggestion.task = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                if self?.suggestion.edits == edits { self?.askNextEdit() }
            }
            return
        }
        suggestion.task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }   // cancelled: a newer edit asks instead
            let raw = await provider(ask.context)
            guard !Task.isCancelled, let self, suggestion.edits == edits,
                textView.selectedRange() == NSRange(location: ask.at, length: 0),
                completion.list?.isOpen != true   // a list that opened meanwhile has the keys
            else { return }
            guard let raw,
                let text = InlineSuggestion.cleaned(
                    raw, rest: ask.rest, below: ask.below, indent: InlineSuggestion.indent(of: ask.context.prefix))
            else { return askNextEdit() }
            show(text, at: ask.at)
            suggestion.taken = false
            suggestion.onEvent?(false)
        }
    }

    private func show(_ text: String, at location: Int) {
        dropNextEdit()
        suggestion.shown = .init(text: text, at: location, length: textView.length)
        showGhost((text, location))
        markBrackets()
    }
}

/// What the suggestion keeps between keys. Only CodeEditor+Suggestion changes it.
struct SuggestionState {
    struct Shown {
        let text: String
        /// Where the gray text starts, and how long the text was then.
        let at: Int, length: Int
    }
    var provider: ((InlineSuggestion.Context) async -> String?)?
    var delay: Duration = .milliseconds(150)
    var task: Task<Void, Never>?
    var shown: Shown?
    var view: GhostTextView?
    var onEvent: ((Bool) -> Void)?
    /// Whether ⇥ or ⌥→ took some of the suggestion that shows.
    var taken = false
    /// Counts edits, so an answer to text that has changed since is thrown away.
    var edits = 0
}
