import AppKit
import Core
import DesignKit
import KelpKit

/// The Skills & MCP panel's rows, drawn: a section's title with its count, a group's line (chevron, name, count and
/// weight), an item (its kind's symbol, name, the agents that get it, what it costs), and what's wrong with one.
@MainActor
struct AddonRows {
    let app: AppModel
    /// A switch was flipped: the key it stands for (`Addon.key`), and whether it's on now.
    var onSwitch: (String, Bool) -> Void = { _, _ in }
    /// A row's file to open: its button under the pointer.
    var onOpen: (String) -> Void = { _ in }
    /// Off Here: the keys to switch off for the project.
    var onOff: ([String]) -> Void = { _ in }
    private static let most = 3

    func section(_ section: AddonLine.Section, count: Int) -> NSView {
        let name: String =
            switch section {
            case .needsLook: String(localized: "Needs a Look")
            case .servers: String(localized: "MCP Servers")
            case .skills: String(localized: "Skills")
            case .instructions: String(localized: "Instructions")
            }
        let title = NSTextField.label(name, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        return line([title, digits(count.formatted()), NSView()], inset: Metrics.inset)
    }

    /// `off`: the group's own switch (a plugin's), nil for a group whose items switch one by one. A plugin's line sits
    /// in the Plugins group, one step in.
    func group(_ g: AddonGroup, count: Int, tokens: Int?, open: Bool, off: Bool?) -> NSView {
        let chevron = NSImageView()
        // A plugin that's off has nothing to unfold: its name still starts where the others do.
        if count > 0 { chevron.image = .symbol(open ? "chevron.down" : "chevron.right") }
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: Self.chevron).isActive = true
        let name = NSTextField.label(
            g.title, font: .ui(TextSize.row), color: off == true ? .secondaryLabelColor : .labelColor)
        var views: [NSView] = [chevron, name, NSView()]
        if count > 0 { views.append(digits(AddonGroups.countAndTokens(count, tokens))) }
        if let off, let key = g.key { views.append(toggle(key, on: !off, name: g.title)) }
        let row = line(views, inset: Self.inset(g.plugin == nil ? 0 : 1))
        row.setAccessibilityLabel(g.title)
        return row
    }

    /// `width`: the row's, so the name gets its room first and what's beside it only what's left. Under the pointer a
    /// row with a file shows a button that opens it.
    func item(_ addon: Addon, depth: Int, width: CGFloat) -> NSView {
        // A plugin's skill sits under its plugin's line: its name there is enough ("sales:call-prep" → "call-prep").
        let title = addon.source == .plugin ? addon.name.split(separator: ":").last.map(String.init) : nil
        let name = NSTextField.label(
            title ?? addon.name, font: .ui(TextSize.row), color: addon.off ? .secondaryLabelColor : .labelColor)
        var held: [NSView] = []
        if AddonGroups.waits(addon) { held.append(waiting()) }
        // A plugin's skill goes with its plugin: the switch is on the plugin's line.
        if let key = addon.key, !key.hasPrefix("plugin:") {
            held.append(toggle(key, on: !addon.off, name: addon.name))
        }
        // What a narrow panel drops, last first: who gets it, what it weighs.
        var extras: [NSView] = []
        if let tokens = addon.tokens { extras.append(digits(shortTokens(tokens))) }
        if let faces = faces(addon.agents) { extras.append(faces) }
        let inset = Self.inset(depth)
        let mark = mark(addon)
        let open = addon.path.map { path in
            IconButton(.symbol("arrow.up.forward.square"), tip: String(localized: "Open")) { onOpen(path) }
        }
        let room = open == nil ? 0 : Metrics.iconButton + Metrics.gap
        let fixed = ([mark, name] + held).reduce(inset + Metrics.inset + room) {
            $0 + $1.fittingSize.width + Metrics.gap
        }
        let shown = AddonGroups.fitting(extras.map { $0.fittingSize.width + Metrics.gap }, in: width - fixed)
        let row = line(
            [mark, name, NSView()] + [open].compactMap { $0 } + extras.prefix(shown).reversed() + held, inset: inset)
        if let open {
            open.isHidden = true
            row.hovered = [open]
        }
        let tip = AddonGroups.tip(addon) { app.catalog.name($0) }
        row.toolTip = tip.isEmpty ? addon.name : addon.name + "\n" + tip
        guard let note = addon.check.flatMap(AddonGroups.checkNote) else { return row }
        return noted(row, note, from: inset + mark.fittingSize.width + Metrics.gap)
    }

    /// An instruction file that needs a look: its row over what's wrong, the whole width under its name, in the
    /// warning colour when agents lose lines.
    private func noted(_ row: AddonCell, _ note: (text: String, warn: Bool), from indent: CGFloat) -> AddonCell {
        let detail = NSTextField.label(
            note.text, font: .ui(TextSize.caption), color: note.warn ? .textOrange : .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let under = NSStackView(views: [detail])
        under.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: Metrics.inset)
        let both = AddonCell(views: [row, under])
        both.orientation = .vertical
        both.alignment = .leading
        both.spacing = Metrics.lineGap
        for part in [row, under] { part.widthAnchor.constraint(equalTo: both.widthAnchor).isActive = true }
        both.hovered = row.hovered
        both.toolTip = row.toolTip
        return both
    }

    /// The switch and the chat disagree until it restarts: a mark that fits the narrowest panel, its words in the tip.
    private func waiting() -> NSView {
        let mark = NSImageView(image: .symbol("arrow.clockwise", String(localized: "After restart")))
        mark.symbolConfiguration = .chrome(Metrics.iconSmall)
        mark.contentTintColor = .textOrange
        mark.toolTip = String(localized: "This chat follows the switch after a restart")
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        return mark
    }

    private func toggle(_ key: String, on: Bool, name: String) -> NSView {
        let control = AddonSwitch(key: key, on: on, changed: onSwitch)
        control.setAccessibilityLabel(name)
        control.toolTip = on ? String(localized: "On in this project") : String(localized: "Off in this project")
        return control
    }

    /// Needs a Look: the name over what's wrong, in red, and a button that switches it off here.
    func problem(_ addon: Addon) -> NSView {
        let off = addon.key.flatMap { addon.off ? nil : [$0] } ?? []
        let row = twoLines(
            addon.name, addon.problem ?? "", color: .textRed, offHere: off, mark: .textRed)
        row.toolTip = [addon.problem, AddonGroups.tip(addon)].compactMap { $0 }.joined(separator: "\n")
        return row
    }

    /// Needs a Look: the servers waiting for a sign-in, as one line with one button for all of them.
    func unsigned(_ servers: [Addon]) -> NSView {
        let text = AddonGroups.unsignedText(servers)
        let row = twoLines(
            text.title, text.detail, color: .secondaryLabelColor, offHere: servers.compactMap(\.key), mark: .textOrange)
        row.toolTip = servers.map(\.name).joined(separator: ", ")
        return row
    }

    private func twoLines(
        _ title: String, _ detail: String, color: NSColor, offHere keys: [String], mark: NSColor
    ) -> AddonCell {
        let warning = NSImageView(image: .symbol("exclamationmark.triangle", String(localized: "Needs a look")))
        warning.symbolConfiguration = .chrome(Metrics.iconSmall)
        warning.contentTintColor = mark
        let words = NSStackView(views: [
            NSTextField.label(title, font: .ui(TextSize.row)),
            NSTextField.label(detail, font: .ui(TextSize.caption), color: color)
        ])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [warning, words, NSView()]
        if !keys.isEmpty {
            let button = TextButton(String(localized: "Off Here")) { onOff(keys) }
            button.toolTip = String(localized: "Off in this project: new chats here don’t get it")
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(button)
        }
        return line(views, inset: Metrics.inset)
    }

    /// The agents that get it, as their icons; nil when the list doesn't say.
    private func faces(_ ids: [String]) -> NSView? {
        guard !ids.isEmpty else { return nil }
        let icons = ids.prefix(Self.most).map {
            NSImageView(image: app.catalog.icon($0, size: Metrics.iconLarge) ?? NSImage())
        }
        let stack = NSStackView(views: icons)
        stack.spacing = Metrics.iconGap
        stack.toolTip = ids.map { app.catalog.name($0) }.joined(separator: ", ")
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    private func mark(_ addon: Addon) -> NSImageView {
        let symbol =
            switch addon.kind {
            case .skill: "doc.text"
            case .server: "server.rack"
            case .instructions: "text.alignleft"
            case .plugin: "puzzlepiece.extension"
            }
        let image = NSImageView(image: .symbol(symbol))
        image.symbolConfiguration = .chrome(Metrics.iconSmall)
        image.contentTintColor = .secondaryLabelColor
        return image
    }

    // MARK: Parts

    /// A group's items start where its name does: each level one chevron and a gap further in.
    private static let chevron: CGFloat = 12
    private static func inset(_ depth: Int) -> CGFloat { Metrics.inset + CGFloat(depth) * (chevron + Metrics.gap) }

    private func digits(_ text: String) -> NSTextField {
        let field = NSTextField.label(text, font: .uiDigits(TextSize.caption), color: .tertiaryLabelColor)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    private func line(_ views: [NSView], inset: CGFloat) -> AddonCell {
        let stack = AddonCell(views: views)
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: Metrics.inset)
        return stack
    }
}

/// A row's switch: the system's small one, which says what it stands for when flipped.
@MainActor
final class AddonSwitch: NSSwitch {
    private let key: String
    private let changed: (String, Bool) -> Void

    init(key: String, on: Bool, changed: @escaping (String, Bool) -> Void) {
        self.key = key
        self.changed = changed
        super.init(frame: .zero)
        controlSize = .mini
        state = on ? .on : .off
        target = self
        action = #selector(flipped)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func flipped() { changed(key, state == .on) }
}

/// A row: under the pointer it shows what waits for it (the button that opens its file).
@MainActor
final class AddonCell: NSStackView, Hoverable {
    var hovered: [NSView] = []
    func setHover(_ on: Bool) { for view in hovered { view.isHidden = !on } }
}
