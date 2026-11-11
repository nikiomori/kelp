import AppKit
import Core
import DesignKit
import KelpKit

/// The boxes of Add a Skill or MCP Server: what was read (its kind, its name, what it signs in with, where it's
/// used), who gets it, and what this Mac has that only some agents see.
@MainActor
enum AddonSheetParts {
    static func text(_ string: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        NSTextField.label(string, font: font, color: color, truncation: .byTruncatingMiddle)
    }

    /// A title over a line about it.
    static func words(_ title: String, _ about: String, mono: Bool = false) -> NSStackView {
        let column = NSStackView(views: [
            text(title, mono ? .uiMono(TextSize.row) : .ui(TextSize.body)),
            text(about, .ui(TextSize.caption), .secondaryLabelColor)
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.lineGap
        return column
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = Metrics.gapWide
        row.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: TextSize.of(Metrics.rowCard)).isActive = true
        return row
    }

    /// Rows on one quiet ground, a hairline between them. The ground is a box behind them: a box sizes nothing by what
    /// it holds, so the rows' stack is what gives the height.
    static func box(_ rows: [NSView]) -> NSView {
        var parts: [NSView] = []
        for row in rows {
            if !parts.isEmpty {
                let line = NSBox()
                line.boxType = .separator
                parts.append(line)
            }
            parts.append(row)
        }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for part in parts { part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let ground = NSBox()
        ground.boxType = .custom
        ground.titlePosition = .noTitle
        ground.fillColor = .fillRest
        ground.borderWidth = 0
        ground.cornerRadius = Metrics.radiusMD
        let holder = NSView()
        holder.pin(ground)
        holder.pin(stack)
        return holder
    }

    static func symbol(_ name: String) -> NSImageView {
        let image = NSImageView(image: .symbol(name))
        image.symbolConfiguration = .chrome(Metrics.iconLarge)
        image.contentTintColor = .secondaryLabelColor
        image.widthAnchor.constraint(equalToConstant: Metrics.iconMenu).isActive = true   // names start in one line
        return image
    }

    static func faces(_ ids: [String], app: AppModel) -> NSStackView {
        let icons = ids.compactMap { id in app.catalog.icon(id, size: Metrics.appIcon).map { NSImageView(image: $0) } }
        let stack = NSStackView(views: icons)
        stack.spacing = Metrics.iconGap
        stack.toolTip = ids.map { app.catalog.name($0) }.joined(separator: ", ")
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    // MARK: What was read

    static func read(_ paste: AddonPaste, in sheet: AddonSheet) -> [NSView] {
        let shared = sheet.scope.selectedSegment == 1
        var rows: [NSView] = []
        switch paste {
        case .server(_, let entry):
            let line = ([entry.command ?? ""] + (entry.args ?? [])).joined(separator: " ")
            let about =
                entry.url.map { String(localized: "Calls \($0)") } ?? String(localized: "Runs \(line) on this Mac")
            sheet.name.font = .ui(TextSize.body)
            sheet.name.placeholderString = String(localized: "Name")
            sheet.name.widthAnchor.constraint(equalToConstant: Metrics.formLabel * 1.5).isActive = true
            rows.append(
                row([symbol("server.rack"), words(String(localized: "MCP Server"), about), NSView(), sheet.name]))
            for key in (entry.env ?? [:]).keys.sorted() {
                rows.append(secret("env:\(key)", key, entry.env?[key], sheet))
            }
            for key in (entry.headers ?? [:]).keys.sorted() {
                rows.append(secret("header:\(key)", key, entry.headers?[key], sheet))
            }
        case .folder(let path):
            rows.append(row([symbol("doc.text"), words(String(localized: "Skill Folder"), path), NSView()]))
        case .repository:
            let about = String(
                localized:
                    "Fetched once with git. Its files can hold scripts the agent may run: only add one you trust.")
            let note = words(String(localized: "Skills from a Repository"), about)
            (note.views.last as? NSTextField)?.lineBreakMode = .byWordWrapping
            (note.views.last as? NSTextField)?.maximumNumberOfLines = 2
            rows.append(row([symbol("doc.text"), note]))
        }
        rows.append(
            row([words(String(localized: "Use in"), place(paste, shared: shared, sheet)), NSView(), sheet.scope]))
        let gets =
            paste.isServer
            ? String(localized: "Handed over when a chat starts; their own settings stay untouched")
            : String(localized: "They read the folder it sits in")
        var who: [NSView] = [
            row([words(String(localized: "Gets it"), gets), NSView(), faces(paste.agents, app: sheet.app)])
        ]
        if paste.isServer {
            let rest = String(localized: "Cursor Agent, Pi and the others take servers only from their own files")
            who.append(row([words(String(localized: "Can’t get it"), rest), NSView()]))
        }
        return [box(rows), box(who)]
    }

    /// Where it will sit, in words under "Use in".
    private static func place(_ paste: AddonPaste, shared: Bool, _ sheet: AddonSheet) -> String {
        switch (paste.isServer, shared) {
        case (true, false): String(localized: "Kelp’s own file, readable by you only")
        case (true, true): String(localized: ".mcp.json: goes to the team with the repository")
        case (false, false): String(localized: "~/.agents/skills, linked for Claude Code")
        case (false, true): String(localized: ".agents/skills in \(sheet.project)’s folder")
        }
    }

    /// What a server signs in with: its name, and its value hidden, to type over.
    private static func secret(_ id: String, _ key: String, _ value: String?, _ sheet: AddonSheet) -> NSView {
        let field = sheet.secrets[id] ?? NSSecureTextField()
        if sheet.secrets[id] == nil {
            field.stringValue = value ?? ""
            field.placeholderString = String(localized: "Value")
            field.widthAnchor.constraint(equalToConstant: Metrics.formLabel * 1.5).isActive = true
            sheet.secrets[id] = field
        }
        let about = String(localized: "What it signs in with")
        return row([symbol("key"), words(key, about, mono: true), NSView(), field])
    }

    // MARK: Found on This Mac

    /// A heading and the rows: a server only one agent has, a skill some agents don't read. nil when there are none.
    static func found(_ sheet: AddonSheet) -> [NSView]? {
        let here = sheet.items.filter { addon in
            if addon.kind == .server { return AddonMenu.only(addon) != nil }
            let own = addon.kind == .skill && (addon.source == .yours || addon.source == .project)
            return own && addon.key != nil && !(addon.agents.contains("claude") && addon.agents.contains("codex"))
        }
        guard !here.isEmpty else { return nil }
        let title = text(
            String(localized: "Found on This Mac"), .ui(TextSize.caption, weight: .semibold), .secondaryLabelColor)
        let rows = here.prefix(6).map { addon -> NSView in
            let names = addon.agents.map { sheet.app.catalog.name($0) }
            let who = ListFormatter.localizedString(byJoining: names)
            let only =
                names.count == 1 ? String(localized: "only \(who) has it") : String(localized: "only \(who) have it")
            let about = text(only, .ui(TextSize.caption), .secondaryLabelColor)
            let line = row([
                symbol(addon.kind == .server ? "server.rack" : "doc.text"), text(addon.name, .ui(TextSize.body)), about,
                NSView()
            ])
            let button = PointerButton(title: String(localized: "Give to All")) {}
            button.onClick = { [weak sheet, weak button, weak about] in
                sheet?.take(addon) {
                    button?.isHidden = true
                    about?.stringValue = String(localized: "every agent has it now")
                }
            }
            line.addArrangedSubview(button)
            return line
        }
        return [title, box(rows)]
    }
}
