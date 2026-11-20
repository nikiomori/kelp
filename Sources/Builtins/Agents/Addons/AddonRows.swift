import AppKit
import Core
import DesignKit
import KelpKit

/// Draws the rows of the Skills & MCP panel. A section row shows its title and count. A group row shows a chevron,
/// the group's name, where its items come from, their count and their weight. An item row shows a symbol for the
/// item's kind, its name, the agents that get it (when that is worth saying), where it comes from and what it costs.
/// A problem row shows what is wrong with an item.
@MainActor
struct AddonRows {
    let app: AppModel
    /// The agent of the chat on screen. A row that only this agent gets needs no agent logo.
    var agent: String?
    /// The switches that were flipped and not answered yet, with the state asked for. Each one is shown held at that
    /// state until the new list comes back.
    var pending: [String: Bool] = [:]
    /// Called when a switch is flipped, with the key the switch stands for (`Addon.key`) and whether it is on now.
    var onSwitch: (String, Bool) -> Void = { _, _ in }
    /// Called with a row's file when the person clicks the Open button that shows under the pointer.
    var onOpen: (String) -> Void = { _ in }
    /// Called by Off Here with the keys to switch off for the project.
    var onOff: ([String]) -> Void = { _ in }
    /// Called by Tidy Up, or by Show Chat while a chat is tidying up. The callbacks below answer Review, Undo and
    /// Keep, which show after a Tidy Up.
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
            case .others: String(localized: "Other Agents")
            }
        // The count sits on the capsule every list's section has, as Source Control's does.
        let trailing = section == .others ? [digits(String(localized: "not in this chat"))] : []
        return SectionHeading(name, count: count, trailing: trailing)
    }

    /// Draws a group's line. `off` is the state of the group's own switch, which only a plugin has; nil for a group
    /// whose items switch one by one. A plugin's line sits inside the Plugins group, indented one step.
    func group(_ addonGroup: AddonGroup, count: Int, tokens: Int?, open: Bool, off: Bool?) -> NSView {
        let chevron = NSImageView()
        // A plugin that is off has nothing to unfold, so it gets no chevron. The empty chevron view still keeps the
        // plugin's name lined up with the others.
        if count > 0 { chevron.image = .symbol(open ? "chevron.down" : "chevron.right") }
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .secondaryLabelColor   // a disclosure chevron is secondary, never tertiary
        chevron.widthAnchor.constraint(equalToConstant: Self.chevron).isActive = true
        let title = addonGroup.agent.map { app.catalog.name($0) } ?? addonGroup.title
        let name = NSTextField.label(
            title, font: .ui(TextSize.row), color: off == true ? .secondaryLabelColor : .labelColor)
        var views: [NSView] = [chevron]
        if let agent = addonGroup.agent { views += faces([agent]).map { [$0] } ?? [] }
        views += [name, NSView()]
        if let source = addonGroup.source, addonGroup.plugin == nil { views.append(scope(source)) }
        if count > 0 { views.append(digits(AddonGroups.countAndTokens(count, tokens))) }
        if let off, let key = addonGroup.key { views.append(toggle(key, on: !off, name: title)) }
        let row = line(views, inset: Self.inset(addonGroup.plugin == nil ? 0 : 1))
        row.setAccessibilityLabel(title)
        return row
    }

    /// Draws an item's row. `width` is the row's width, so the name gets its room first and the marks beside it get
    /// only what is left. `parent` is the group the row sits under. That group already says where the item comes from
    /// (or, for an agent's group, which agent gets it). Under the pointer, a row with a file shows a button that opens
    /// the file.
    func item(_ addon: Addon, depth: Int, width: CGFloat, parent: AddonGroup? = nil) -> NSView {
        // A plugin's skill sits under the plugin's line, so the skill's bare name is enough there ("sales:call-prep"
        // → "call-prep").
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
        // A plugin's skill goes on and off with its plugin, so the skill's row has no switch. The switch is on the
        // plugin's line.
        if let key = addon.key, !key.hasPrefix("plugin:") {
            held.append(toggle(key, on: !addon.off, name: addon.name))
        }
        // A narrow panel drops these marks from the end of the list: first the agents that get the item, then where
        // it comes from, then what it weighs.
        var extras: [NSView] = []
        if let tokens = now ?? addon.tokens { extras.append(digits(shortTokens(tokens))) }
        if parent == nil || parent?.agent != nil { extras.append(scope(addon.source)) }
        let implied = parent?.agent ?? agent
        if addon.agents != [implied].compactMap({ $0 }), let faces = faces(addon.agents) { extras.append(faces) }
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

    /// A mark that says the switch and the chat disagree until the chat restarts. It fits the narrowest panel, and its
    /// words are in the tooltip.
    private func waiting(_ tip: String = String(localized: "This chat follows the switch after a restart")) -> NSView {
        let mark = NSImageView(image: .symbol("arrow.triangle.2.circlepath", String(localized: "After restart")))
        mark.symbolConfiguration = .chrome(Metrics.iconSmall)
        mark.contentTintColor = .textOrange
        mark.toolTip = tip
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        return mark
    }

    /// Returns the switch. While the daemon answers, the switch is held at the state asked for, dimmed, with the
    /// system's small spinner beside it (the turning ring is an agent's mark for working).
    private func toggle(_ key: String, on: Bool, name: String) -> NSView {
        let asked = pending[key]
        let control = AddonSwitch(key: key, on: asked ?? on, changed: onSwitch)
        control.setAccessibilityLabel(name)
        control.toolTip = on ? String(localized: "On in this project") : String(localized: "Off in this project")
        guard asked != nil else { return control }
        control.isEnabled = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let held = NSStackView(views: [spinner, control])
        held.spacing = Metrics.gap
        held.setContentCompressionResistancePriority(.required, for: .horizontal)
        return held
    }

    /// Shows where an item comes from as a quiet symbol, with the words in the tooltip.
    private func scope(_ source: Addon.Source) -> NSView {
        let mark = NSImageView(image: .symbol(source.symbol, source.words))
        mark.symbolConfiguration = .chrome(Metrics.iconSmall)
        mark.contentTintColor = .secondaryLabelColor   // the only place the row says where the item is from
        mark.toolTip = source.words
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        return mark
    }

    /// A Needs a Look row with the item's name above what is wrong with it, in red, and an Off Here button that
    /// switches the item off for this project.
    func problem(_ addon: Addon) -> NSView {
        let off = addon.key.flatMap { addon.off ? nil : [$0] } ?? []
        let row = twoLines(addon.name, addon.problem ?? "", color: .textRed, buttons: offHere(off), mark: .textRed)
        row.toolTip = [addon.problem, AddonGroups.tip(addon)].compactMap { $0 }.joined(separator: "\n")
        return row
    }

    /// A Needs a Look row for the servers that wait for a sign-in, with one button that switches all of them off.
    func unsigned(_ servers: [Addon]) -> NSView {
        let text = AddonGroups.unsignedText(servers)
        let row = twoLines(
            text.title, text.detail, color: .secondaryLabelColor, buttons: offHere(servers.compactMap(\.key)),
            mark: .textOrange)
        row.toolTip = servers.map(\.name).joined(separator: ", ")
        return row
    }

    /// The Needs a Look row for the project's instruction files. It has three states, each with its own buttons: what
    /// the files cost every chat and the worst problem in them (Tidy Up), an agent shortening them (Show Chat), or what
    /// the agent saved (Keep, Review, Undo).
    func instructions(_ files: [Addon], tidied: Tidied?, working: Bool) -> NSView {
        let name = String(localized: "Instructions")
        if working {
            let show = button(String(localized: "Show Chat"), String(localized: "A chat is shortening them"), onTidy)
            return twoLines(
                name, String(localized: "An agent is shortening them"), color: .secondaryLabelColor, buttons: [show],
                symbol: "ellipsis.circle", mark: .secondaryLabelColor)
        }
        if let tidied {
            // The files are saved already. Keep closes this row, Review shows the changes, and Undo takes them back.
            let saved = "\(shortTokens(tidied.tokensBefore)) → \(shortTokens(tidied.tokensNow))"
            let keep = button(String(localized: "Keep"), String(localized: "The changes stay: close this"), onKeep)
            let review = button(String(localized: "Review"), String(localized: "Every change, file by file"), onReview)
            // It asks first, so its name ends in "…".
            let undo = button(String(localized: "Undo…"), String(localized: "Put the files back as they were"), onUndo)
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

    /// Returns the Off Here button, which switches the keys off for the project; empty when there is nothing to switch.
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
        // The buttons get a third line of their own, so a narrow panel has room for both the words and the buttons.
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

    /// Returns the icons of the agents that get an item; nil when the item names no agents.
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

    /// A group's items start where the group's name does, so each level is indented by one chevron and a gap.
    private static let chevron: CGFloat = 12
    private static func inset(_ depth: Int) -> CGFloat { Metrics.inset + CGFloat(depth) * (chevron + Metrics.gap) }

    private func digits(_ text: String) -> NSTextField {
        let field = NSTextField.label(text, font: .uiDigits(TextSize.caption), color: .secondaryLabelColor)
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

/// The switch on a row. It is the system's mini switch, and when flipped it reports the key it stands for.
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

/// A row of the panel. Under the pointer it shows its hidden views, such as the button that opens the item's file.
@MainActor
final class AddonCell: NSStackView, Hoverable {
    var hovered: [NSView] = []
    func setHover(_ on: Bool) {
        if !hovered.isEmpty { crossfade() }   // the Open button fades in and out, as every list's row actions do
        for view in hovered { view.isHidden = !on }
    }
}
