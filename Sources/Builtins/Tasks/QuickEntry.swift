import AppKit
import Carbon.HIToolbox
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// Quick Entry: ⌃⌥⌘T from any app writes a task down without bringing Kelp forward. One field, as Quick Open's and
/// the switcher's card (440 wide, the field's size), and where the line goes: the inbox of the project on screen
/// unless To says otherwise. Return writes it; ⌘Return writes it and shows it on its page; Escape closes and keeps
/// what was typed for next time.
@MainActor
final class QuickEntry: NSObject, NSTextFieldDelegate {
    private static var one: QuickEntry?
    static func shared(_ app: AppModel) -> QuickEntry {
        if let one { return one }
        let made = QuickEntry(app: app)
        one = made
        return made
    }

    private let app: AppModel
    private var panel: NSPanel?
    private let field = NSTextField()
    private let to = NSPopUpButton()
    private var hotKey: EventHotKeyRef?
    /// The code the line is about, when it was written down with code selected in Kelp's editor: `path:line` in the
    /// project, said under the field and added to the line.
    private var code: String?
    private let from = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    /// Where each item of To sends the line: a project, and a heading of its list (nil: its inbox).
    private var places: [(repo: String, under: String?)] = []

    private init(app: AppModel) { self.app = app }

    /// Shows the card, the line going to `repo`'s inbox unless the person picks another place.
    func show(repo: String?) {
        code = NSApp.isActive ? Self.codeHere(app) : nil
        let panel = self.panel ?? make()
        from.stringValue = code.map { "↪ " + $0 } ?? ""
        from.isHidden = code == nil
        fillPlaces(repo: repo ?? app.worktree(app.workbench.workspaceId)?.repoId)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame, size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    private func make() -> NSPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.switcherWidth, height: 96),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.panel?.orderOut(nil) }   // what was typed stays for next time
        let ground = NSVisualEffectView()
        ground.material = .popover
        ground.state = .active
        ground.wantsLayer = true
        ground.layer?.cornerRadius = Metrics.radiusXL
        panel.contentView = ground

        let box = NSImageView(image: .symbol("square"))
        box.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .ui(TextSize.heading)
        field.placeholderString = String(localized: "New Task")
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "New Task"))
        let top = NSStackView(views: [box, field])
        top.spacing = Metrics.gap
        to.controlSize = .small
        to.font = .ui(TextSize.caption)
        let hint = NSTextField.label(
            String(localized: "↩ Save   ⌘↩ Save and Open"), font: .ui(TextSize.caption), color: .secondaryLabelColor)
        let foot = NSStackView(views: [
            NSTextField.label(String(localized: "To:"), font: .ui(TextSize.caption)), to, NSView(), hint
        ])
        foot.spacing = Metrics.gap
        from.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [top, from, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.sheetInset, left: Metrics.sheetInset, bottom: Metrics.inset, right: Metrics.sheetInset)
        for row in [top, foot] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.sheetInset).isActive = true
        }
        ground.pin(stack)
        self.panel = panel
        return panel
    }

    /// To's items: the project's list headings first (its inbox chosen), then the other projects' inboxes.
    private func fillPlaces(repo: String?) {
        to.removeAllItems()
        places = []
        let repos = app.repos.sorted { ($0.id == repo ? 0 : 1, $0.name) < ($1.id == repo ? 0 : 1, $1.name) }
        for (i, project) in repos.enumerated() {
            let headings =
                i == 0
                ? app.latest(TasksEvent.self, project.id)?.pages.first(where: { $0.isList == true })?.sections ?? []
                : []
            if headings.isEmpty {
                to.addItem(withTitle: "\(project.name) › \(String(localized: "Inbox"))")
                places.append((project.id, nil))
                to.lastItem?.tag = places.count - 1
            }
            for heading in headings {
                to.addItem(withTitle: "\(project.name) › \(heading)")
                places.append((project.id, heading == headings.first ? nil : heading))
                to.lastItem?.tag = places.count - 1
            }
            if i == 0, repos.count > 1 { to.menu?.addItem(.separator()) }
        }
        to.selectItem(at: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        save(andOpen: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        return true
    }

    private func save(andOpen: Bool) {
        let words = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = to.selectedItem?.tag ?? -1
        guard !words.isEmpty, places.indices.contains(picked) else { return NSSound.beep() }
        let place = places[picked], app = self.app
        Task {
            let text = code.map { "\(words) (`\($0)`)" } ?? words
            guard let made = await TaskActions.add(app, repo: place.repo, text: text, under: place.under) else {
                return
            }
            code = nil
            field.stringValue = ""
            panel?.orderOut(nil)
            if andOpen {
                NSApp.activate()
                app.workbench.bringToFront()
                app.workbench.open(TabURI.file(made.path, line: made.task.line))
            }
        }
    }

    /// The selection in Kelp's focused editor as `path:line` in its project (or the line with the cursor).
    static func codeHere(_ app: AppModel) -> String? {
        guard let editor = CodeEditor.focused, let file = app.workbench.focusedContent?.fileURL?.path,
            let lines = editor.selectedLines ?? editor.cursor.map({ $0.line...$0.line })
        else { return nil }
        let root = app.worktree(app.workbench.workspaceId)?.path
        let path = root.map { Paths.inside(file, $0) ? String(file.dropFirst($0.count + 1)) : file } ?? file
        return lines.count > 1 ? "\(path):\(lines.lowerBound)-\(lines.upperBound)" : "\(path):\(lines.lowerBound)"
    }

    /// Registers ⌃⌥⌘T from any app (a Carbon hot key, so no Accessibility permission is needed), as ⌃⌥⌘K is.
    /// The result is the system's answer: an error when the keys can't be had.
    @discardableResult func registerHotKey() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, me in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard let me, id.signature == QuickEntry.signature else { return OSStatus(eventNotHandledErr) }
                let entry = Unmanaged<QuickEntry>.fromOpaque(me).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { entry.show(repo: nil) } }   // the main queue
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        return RegisterEventHotKey(
            UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
    func unregisterHotKey() { hotKey.map { _ = UnregisterEventHotKey($0) } }
    nonisolated static let signature = OSType(0x4B54534B)   // 'KTSK'
}

/// A panel that takes the keys without bringing Kelp forward, and closes on Escape.
private final class KeyPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}
