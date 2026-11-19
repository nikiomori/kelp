import AppKit
import Core
import DesignKit
import KelpKit

/// The Add a Skill or MCP Server sheet. It has one field for whatever the person has at hand (a command, an address,
/// JSON, a skill's folder or a repository of skills). Under the field it shows what Kelp read from it, where it will
/// be used, and which agents get it. Then it lists what this Mac already has that only some agents see, each handed on
/// with one click. Editing a server uses the same sheet, filled in.
@MainActor
final class AddonSheet: NSObject, NSTextFieldDelegate {
    enum Added {
        case server(name: String, entry: ServerEntry, project: Bool)
        case skills(source: String, project: Bool)
    }
    typealias Editing = (name: String, json: String, project: Bool)

    let app: AppModel, worktreeId: String, project: String, items: [Addon], editing: Editing?
    let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: Metrics.sheetWidth, height: 1), styleMask: [.titled],
        backing: .buffered, defer: true)
    let field = NSTextField()
    let name = NSTextField()
    let scope = CapsuleSegments(labels: [], name: String(localized: "Where It Works"))
    /// The boxes that show what Kelp read and who gets it, rebuilt as the field changes.
    let read = NSStackView()
    private let add = NSButton()
    private(set) var paste: AddonPaste?
    /// The fields for what a server signs in with, keyed by "env:KEY" or "header:KEY". Values typed here replace the
    /// ones that were pasted.
    var secrets: [String: NSSecureTextField] = [:]
    /// True once the sheet has handed on something found on this Mac, so the list is read again however the sheet ends.
    private(set) var changed = false

    init(app: AppModel, worktreeId: String, project: String, items: [Addon], editing: Editing? = nil) {
        self.app = app
        self.worktreeId = worktreeId
        self.project = project
        self.items = items
        self.editing = editing
        super.init()
        build()
    }

    /// Shows the sheet and returns what to add; nil when cancelled. `changed` says whether the sheet handed something
    /// on meanwhile.
    func ask() async -> Added? {
        guard await runSheet(window) == .OK, let paste else { return nil }
        let shared = scope.selectedSegment == 1
        switch paste {
        case .server(let parsed, var entry):
            for (key, field) in secrets where !field.stringValue.isEmpty {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                if parts[0] == "env" { entry.env?[parts[1]] = field.stringValue }
                if parts[0] == "header" { entry.headers?[parts[1]] = field.stringValue }
            }
            let typed = name.stringValue.trimmingCharacters(in: .whitespaces)
            return .server(name: typed.isEmpty ? parsed : typed, entry: entry, project: shared)
        case .folder(let path), .repository(let path): return .skills(source: path, project: shared)
        }
    }

    private func build() {
        let title = AddonSheetParts.text(
            editing.map { String(localized: "Edit “\($0.name)”") } ?? String(localized: "Add a Skill or MCP Server"),
            .ui(TextSize.body, weight: .semibold))
        field.placeholderString = String(localized: "A command, an address, JSON, or a skill’s folder or repository")
        field.font = .uiMono(TextSize.row)
        field.controlSize = .large
        field.delegate = self
        let choose = ClosureButton(title: String(localized: "Choose…")) { [weak self] in self?.chooseFolder() }
        choose.bezelStyle = .push   // a sheet's button is the system's
        let entry = NSStackView(views: editing == nil ? [field, choose] : [field])
        entry.spacing = Metrics.gapWide
        scope.segmentCount = 2
        scope.setLabel(String(localized: "All Projects"), forSegment: 0)
        scope.setLabel(String(localized: "Only \(project)"), forSegment: 1)
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(scopeChanged)
        read.orientation = .vertical
        read.alignment = .leading
        read.spacing = Metrics.inset
        if let editing {   // the entry shows as its file spells it, and the scope is locked so it stays in that file
            field.stringValue = editing.json
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            scope.selectedSegment = editing.project ? 1 : 0
            scope.isEnabled = false
        }
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        add.title = editing == nil ? String(localized: "Add") : String(localized: "Save")
        add.bezelStyle = .push
        add.keyEquivalent = "\r"
        add.target = self
        add.action = #selector(confirmed)
        let buttons = NSStackView(views: [NSView(), cancel, add])
        buttons.spacing = Metrics.gapWide
        var parts: [NSView] = [title, entry, read]
        var wide: [NSView] = [entry, read, buttons]
        if editing == nil, let found = AddonSheetParts.found(self) {
            parts += found
            wide += found
        }
        parts.append(buttons)
        window.contentView = SheetForm.stack(parts, wide: wide, width: Metrics.sheetWidth)
        window.initialFirstResponder = field
        show()
    }

    func controlTextDidChange(_ note: Notification) {
        if (note.object as? NSTextField) === field { show() }
    }

    /// Rebuilds the boxes under the field for what the field holds now, and resizes the sheet to fit them.
    private func show() {
        let now = AddonPaste.read(field.stringValue)
        // While the field still holds the same kind of thing, typing in it keeps what was typed into the boxes below.
        let same = now?.isServer == paste?.isServer && now != nil
        paste = now
        if !same { secrets = [:] }
        if case .server(let parsed, _) = now, !same || name.stringValue.isEmpty { name.stringValue = parsed }
        read.setViews(now.map { AddonSheetParts.read($0, in: self) } ?? [], in: .top)
        read.isHidden = now == nil
        add.isEnabled = now != nil
        window.setContentSize(
            NSSize(width: Metrics.sheetWidth, height: window.contentView?.fittingSize.height ?? 0))
    }

    @objc private func scopeChanged() { show() }
    @objc private func cancelled() { window.sheetParent?.endSheet(window, returnCode: .cancel) }
    @objc private func confirmed() { window.sheetParent?.endSheet(window, returnCode: .OK) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        panel.beginSheetModal(for: window) { [weak self] answer in
            // AppKit calls back on the main thread.
            MainActor.assumeIsolated {
                guard answer == .OK, let self, let url = panel.url else { return }
                self.field.stringValue = url.path
                self.show()
            }
        }
    }

    /// Hands on an item the person picked under Found on This Mac at once, with the same calls that the menus on the
    /// panel's rows make.
    func take(_ addon: Addon, done: @escaping () -> Void) {
        guard let key = addon.key else { return }
        Task { [app, worktreeId] in
            if addon.kind == .server, let agent = AddonMenu.only(addon) {
                let name = String(key.dropFirst("server:".count))
                guard await app.call(AddonsAdd(worktreeId: worktreeId, name: name, entry: nil, from: agent)) != nil
                else { return }
            } else {
                guard await app.call(AddonsLink(worktreeId: worktreeId, key: key)) != nil else { return }
            }
            self.changed = true
            done()
        }
    }
}
