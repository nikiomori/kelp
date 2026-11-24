import AppKit
import Core
import DesignKit
import KelpKit

/// Builds the boxes of the Add a Skill or MCP Server sheet. They show what was read (its kind, its name, what it signs
/// in with, where it is used), who gets it, and what this Mac has that only some agents see.
@MainActor
enum AddonSheetParts {
    static func text(_ string: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        NSTextField.label(string, font: font, color: color, truncation: .byTruncatingMiddle)
    }

    /// A title with a line about it underneath. The title, a name, is cut in its middle; the line about it is a
    /// sentence, so it takes a second line instead of being cut.
    static func words(_ title: String, _ about: String, mono: Bool = false) -> NSStackView {
        let line = text(about, .ui(TextSize.caption), .secondaryLabelColor)
        line.lineBreakMode = .byWordWrapping
        line.maximumNumberOfLines = 2
        let column = NSStackView(views: [text(title, mono ? .uiMono(TextSize.row) : .ui(TextSize.body)), line])
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

    /// Puts rows on one quiet background with a hairline between them. The background is a box behind the rows. A box
    /// doesn't size itself to what it holds, so the stack of rows gives the height.
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
        image.widthAnchor.constraint(equalToConstant: Metrics.iconMenu).isActive = true   // so the names line up
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
            let folder = words(String(localized: "Skill Folder"), path)
            (folder.views.last as? NSTextField)?.lineBreakMode = .byTruncatingMiddle   // a path: its end matters
            (folder.views.last as? NSTextField)?.maximumNumberOfLines = 1
            rows.append(row([symbol("doc.text"), folder, NSView()]))
        case .repository:
            let about = String(
                localized:
                    "Fetched once with git. Its files can hold scripts the agent may run: only add one you trust.")
            rows.append(row([symbol("doc.text"), words(String(localized: "Skills from a Repository"), about)]))
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

    /// Says where the item will be saved, in the words shown under "Use in".
    private static func place(_ paste: AddonPaste, shared: Bool, _ sheet: AddonSheet) -> String {
        switch (paste.isServer, shared) {
        case (true, false): String(localized: "Kelp’s own file, readable by you only")
        case (true, true): String(localized: ".mcp.json: goes to the team with the repository")
        case (false, false): String(localized: "~/.agents/skills, linked for Claude Code")
        case (false, true): String(localized: ".agents/skills in \(sheet.project)’s folder")
        }
    }

    /// A row for one value a server signs in with: the value's name, and the value itself hidden, to type over.
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

    /// Returns the Found on This Mac heading and its rows: servers only one agent has, and skills some agents don't
    /// read. nil when there are none.
    static func found(_ sheet: AddonSheet) -> [NSView]? {
        let here = sheet.items.filter { addon in
            addon.kind == .server
                ? AddonMenu.only(addon) != nil : addon.kind == .skill && AddonMenu.notEveryAgentHas(addon)
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
            // A row's worded button in a sheet is the system's small one. Once taken, it goes: it's the row's last view.
            let button = ClosureButton(title: String(localized: "Give to All")) { [weak sheet, weak line, weak about] in
                sheet?.take(addon) {
                    line?.arrangedSubviews.last?.isHidden = true
                    about?.stringValue = String(localized: "every agent has it now")
                }
            }
            button.bezelStyle = .push
            button.controlSize = .small
            line.addArrangedSubview(button)
            return line
        }
        return [title, box(rows)]
    }
}
