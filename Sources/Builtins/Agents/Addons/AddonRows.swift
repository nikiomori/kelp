import AppKit
import Core
import DesignKit
import KelpKit

/// The Skills & MCP panel's rows, drawn: a section's title with its count, a group's line (chevron, name, count), an
/// item (its kind's symbol, name, where it is, the agents that get it, what it costs), and what's wrong with one.
@MainActor
struct AddonRows {
    let app: AppModel
    /// A switch was flipped: the key it stands for (`Addon.key`), and whether it's on now.
    var onSwitch: (String, Bool) -> Void = { _, _ in }
    private static let most = 3

    func section(_ section: AddonLine.Section, count: Int) -> NSView {
        let name: String =
            switch section {
            case .needsLook: String(localized: "Needs a Look")
            case .servers: String(localized: "MCP Servers")
            case .skills: String(localized: "Skills")
            case .instructions: String(localized: "Instructions")
            }
        let title = label(name, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        return line([title, digits(count), NSView()], inset: Metrics.inset)
    }

    /// `off`: the group's own switch (a plugin's), nil for a group whose items switch one by one.
    func group(_ g: AddonGroup, count: Int, open: Bool, off: Bool?) -> NSView {
        let chevron = NSImageView()
        // A plugin that's off has nothing to unfold: its name still starts where the others do.
        if count > 0 { chevron.image = .symbol(open ? "chevron.down" : "chevron.right") }
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: Self.chevron).isActive = true
        let name = label(g.title, font: .ui(TextSize.row), color: off == true ? .secondaryLabelColor : .labelColor)
        var views: [NSView] = [chevron, name, NSView()]
        if count > 0 { views.append(digits(count)) }
        if let off, let key = g.key { views.append(toggle(key, on: !off, name: g.title)) }
        let row = line(views, inset: Metrics.inset)
        row.setAccessibilityLabel(g.title)
        return row
    }

    /// `width`: the row's, so the name gets its room first and what's beside it only what's left.
    func item(_ addon: Addon, nested: Bool, width: CGFloat) -> NSView {
        let name = label(addon.name, font: .ui(TextSize.row), color: addon.off ? .secondaryLabelColor : .labelColor)
        var held: [NSView] = []
        if AddonGroups.waits(addon) { held.append(waiting()) }
        // A plugin's skill goes with its plugin: the switch is on the plugin's line.
        if let key = addon.key, !key.hasPrefix("plugin:") {
            held.append(toggle(key, on: !addon.off, name: addon.name))
        }
        // What a narrow panel drops, last first: where it is, who gets it, what it weighs.
        var extras: [NSView] = []
        if let tokens = addon.tokens { extras.append(caption(AddonGroups.tokens(tokens), truncating: false)) }
        if let faces = faces(addon.agents) { extras.append(faces) }
        if addon.kind != .skill, let origin = addon.origin { extras.append(caption(origin, truncating: false)) }
        let inset = nested ? Self.nested : Metrics.inset
        let mark = mark(addon)
        let fixed = ([mark, name] + held).reduce(inset + Metrics.inset) { $0 + $1.fittingSize.width + Metrics.gap }
        let shown = AddonGroups.fitting(extras.map { $0.fittingSize.width + Metrics.gap }, in: width - fixed)
        let row = line([mark, name, NSView()] + extras.prefix(shown).reversed() + held, inset: inset)
        let tip = AddonGroups.tip(addon) { app.catalog.name($0) }
        row.toolTip = tip.isEmpty ? addon.name : addon.name + "\n" + tip
        return row
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

    /// Needs a Look: the name over what's wrong, in red.
    func problem(_ addon: Addon) -> NSView {
        let warning = NSImageView(image: .symbol("exclamationmark.triangle", String(localized: "Problem")))
        warning.symbolConfiguration = .chrome(Metrics.iconSmall)
        warning.contentTintColor = .textRed
        let words = NSStackView(views: [
            label(addon.name, font: .ui(TextSize.row)),
            label(addon.problem ?? "", font: .ui(TextSize.caption), color: .textRed)
        ])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = line([warning, words, NSView()], inset: Metrics.inset)
        row.toolTip = [addon.problem, AddonGroups.tip(addon)].compactMap { $0 }.joined(separator: "\n")
        return row
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

    /// A group's items start where its name does.
    private static let chevron: CGFloat = 12
    private static var nested: CGFloat { Metrics.inset + chevron + Metrics.gap }

    private func digits(_ n: Int) -> NSTextField {
        let field = label(n.formatted(), font: .uiDigits(TextSize.caption), color: .tertiaryLabelColor)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    private func caption(_ text: String, truncating: Bool, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = label(text, font: .uiDigits(TextSize.caption), color: color)
        if truncating {   // where it is gives way before the name does
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        } else {
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return field
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func line(_ views: [NSView], inset: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
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
