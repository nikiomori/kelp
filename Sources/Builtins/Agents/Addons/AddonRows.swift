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
    /// Tidy Up, or Show Chat while one tidies up; then Review and Undo.
    var onTidy: () -> Void = {}
    var onReview: () -> Void = {}
    var onUndo: () -> Void = {}
    var onKeep: () -> Void = {}
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
        let now = AddonGroups.behind(addon)
        if let now, let then = addon.tokens {
            held.append(
                waiting(
                    String(
                        localized:
                            "This chat read \(shortTokens(then)) when it started: new chats read \(shortTokens(now)). Restart it to read them too."
                    )))
        }
        // A plugin's skill goes with its plugin: the switch is on the plugin's line.
        if let key = addon.key, !key.hasPrefix("plugin:") {
            held.append(toggle(key, on: !addon.off, name: addon.name))
        }
        // What a narrow panel drops, last first: who gets it, what it weighs.
        var extras: [NSView] = []
        if let tokens = now ?? addon.tokens { extras.append(digits(shortTokens(tokens))) }
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
        return row
    }

    /// The switch and the chat disagree until it restarts: a mark that fits the narrowest panel, its words in the tip.
    private func waiting(_ tip: String = String(localized: "This chat follows the switch after a restart")) -> NSView {
        let mark = NSImageView(image: .symbol("arrow.clockwise", String(localized: "After restart")))
        mark.symbolConfiguration = .chrome(Metrics.iconSmall)
        mark.contentTintColor = .textOrange
        mark.toolTip = tip
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
        let row = twoLines(addon.name, addon.problem ?? "", color: .textRed, buttons: offHere(off), mark: .textRed)
        row.toolTip = [addon.problem, AddonGroups.tip(addon)].compactMap { $0 }.joined(separator: "\n")
        return row
    }

    /// Needs a Look: the servers waiting for a sign-in, as one line with one button for all of them.
    func unsigned(_ servers: [Addon]) -> NSView {
        let text = AddonGroups.unsignedText(servers)
        let row = twoLines(
            text.title, text.detail, color: .secondaryLabelColor, buttons: offHere(servers.compactMap(\.key)),
            mark: .textOrange)
        row.toolTip = servers.map(\.name).joined(separator: ", ")
        return row
    }

    /// Needs a Look: the project's instruction files, in one of three states: what they cost every chat and the worst
    /// of what's wrong (Tidy Up); an agent shortening them (Show Chat); what it saved (Review, Undo).
    func instructions(_ files: [Addon], tidied: Tidied?, working: Bool) -> NSView {
        let name = String(localized: "Instructions")
        if working {
            let show = button(String(localized: "Show Chat"), String(localized: "A chat is shortening them"), onTidy)
            return twoLines(
                name, String(localized: "An agent is shortening them"), color: .secondaryLabelColor, buttons: [show],
                symbol: "ellipsis.circle", mark: .secondaryLabelColor)
        }
        if let tidied {
            // Saved already: Keep closes this, Review shows it, Undo takes it back.
            let saved = "\(shortTokens(tidied.tokensBefore)) → \(shortTokens(tidied.tokensNow))"
            let keep = button(String(localized: "Keep"), String(localized: "The changes stay: close this"), onKeep)
            let review = button(String(localized: "Review"), String(localized: "Every change, file by file"), onReview)
            let undo = button(String(localized: "Undo"), String(localized: "Put the files back as they were"), onUndo)
            let row = twoLines(
                tidied.changed == 0 ? String(localized: "Nothing changed") : String(localized: "Saved"),
                String(localized: "\(saved) tokens in new chats"), color: .secondaryLabelColor,
                buttons: [keep, review, undo], symbol: "checkmark.circle", mark: .secondaryLabelColor,
                buttonsUnder: true)
            row.toolTip = String(
                localized:
                    "The instruction files are saved: new chats read \(saved) tokens. A chat open now keeps what it read until it restarts."
            )
            return row
        }
        let text = AddonGroups.instructionsText(files)
        let cost = files.compactMap(\.tokens).reduce(0, +)
        let tidy = button(
            TidyUp.title, String(localized: "An agent shortens them now: review or undo afterwards"), onTidy)
        let row = twoLines(
            cost > 0 ? String(localized: "\(name) · \(shortTokens(cost)) tokens a chat") : name, text.detail,
            color: text.warn ? .textOrange : .secondaryLabelColor, buttons: [tidy], mark: .textOrange)
        row.toolTip = files.map { file in
            ([file.name] + (file.check.map { AddonGroups.findings($0, name: file.name) } ?? [])).joined(separator: "\n")
        }.joined(separator: "\n\n")
        return row
    }

    private func button(_ title: String, _ tip: String, _ action: @escaping () -> Void) -> TextButton {
        let button = TextButton(title) { action() }
        button.toolTip = tip
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// Off Here: switches the keys off for the project; nil when there's nothing to switch.
    private func offHere(_ keys: [String]) -> [TextButton] {
        guard !keys.isEmpty else { return [] }
        let tip = String(localized: "Off in this project: new chats here don’t get it")
        return [button(String(localized: "Off Here"), tip) { onOff(keys) }]
    }

    private func twoLines(
        _ title: String, _ detail: String, color: NSColor, buttons: [TextButton],
        symbol: String = "exclamationmark.triangle", mark: NSColor, buttonsUnder: Bool = false
    ) -> AddonCell {
        let warning = NSImageView(image: .symbol(symbol, String(localized: "Needs a look")))
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
        guard buttonsUnder else { return line([warning, words, NSView()] + buttons, inset: Metrics.inset) }
        // A third line of their own, where a narrow panel has room for the words and the buttons both.
        let row = NSStackView(views: buttons)
        row.spacing = Metrics.gap
        words.addArrangedSubview(row)
        words.setCustomSpacing(Metrics.gap, after: words.arrangedSubviews[1])
        warning.setContentHuggingPriority(.required, for: .horizontal)
        let cell = line([warning, words, NSView()], inset: Metrics.inset)
        cell.alignment = .top
        cell.edgeInsets.top = Metrics.gap
        return cell
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
