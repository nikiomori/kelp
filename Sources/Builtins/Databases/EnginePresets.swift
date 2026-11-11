import AppKit
import Core
import DesignKit
import KelpKit

/// What Add Database offers to start from: the engines Kelp speaks, and services it opens with one of them (Supabase is
/// Postgres with SSL on 5432 or its pooler's 6543…). Each fills the form's port, SSL and a word on where its address is.
struct EnginePreset {
    var name: String, letters: String, color: String, dark = false
    var engine: DatabaseInfo.Engine
    /// Its own port, where it isn't the engine's (`DatabaseInfo.Engine.defaultPort`).
    var port: Int?
    var ssl: String?
    /// Where its address is, said under the form's fields.
    var hint: String?
    /// "Postgres" under a service's name: what Kelp opens it as.
    var speaks: String?

    static let all: [EnginePreset] = [
        .init(name: "Postgres", letters: "Pg", color: "336791", engine: .postgres),
        .init(name: "MySQL", letters: "My", color: "00758F", engine: .mysql),
        .init(name: "MariaDB", letters: "Ma", color: "4A8A9C", engine: .mysql),
        .init(name: "SQLite", letters: "Sl", color: "4A7BAB", engine: .sqlite),
        .init(name: "DuckDB", letters: "Du", color: "1C1C1E", engine: .duckdb),
        .init(
            name: "Appwrite", letters: "Aw", color: "FD366E", engine: .appwrite,
            hint:
                "Endpoint: your Appwrite's address. Project ID: the project's Settings. API key: Overview › API keys, "
                + "with databases.read, tables.read, rows.read and rows.write. No SQL there: Kelp turns its pages, "
                + "filters and edits into Appwrite's queries."),
        .init(
            name: "Supabase", letters: "Sb", color: "3ECF8E", dark: true, engine: .postgres, port: 5432,
            ssl: "require", hint: "Project Settings › Database › Connection string (or the pooler's, port 6543).",
            speaks: "Postgres"),
        .init(
            name: "Neon", letters: "Ne", color: "00E599", dark: true, engine: .postgres, port: 5432, ssl: "require",
            hint: "The project's Dashboard › Connection Details: paste the whole postgres:// line.",
            speaks: "Postgres"),
        .init(
            name: "CockroachDB", letters: "Cr", color: "6933FF", engine: .postgres, port: 26257, ssl: "require",
            hint: "Connect › General connection string.", speaks: "Postgres"),
        .init(
            name: "Redshift", letters: "Rs", color: "205B8F", engine: .postgres, port: 5439, ssl: "require",
            hint: "The cluster's Endpoint, without its :5439/db tail.", speaks: "Postgres"),
        .init(
            name: "Timescale", letters: "Ts", color: "FDB515", dark: true, engine: .postgres, port: 5432,
            ssl: "require", hint: "The service's Connection info.", speaks: "Postgres"),
        .init(
            name: "PlanetScale", letters: "Ps", color: "2C2C2E", engine: .mysql, port: 3306, ssl: "require",
            hint: "Connect › General: host, user and password of a branch.", speaks: "MySQL"),
        .init(
            name: "libSQL file", letters: "Ls", color: "4FF8D2", dark: true, engine: .sqlite,
            hint: "A local Turso/libSQL database file: Kelp opens it as SQLite.", speaks: "SQLite")
    ]

    /// The engine's own: the first of its presets that is no service.
    static func of(_ engine: DatabaseInfo.Engine) -> EnginePreset {
        all.first { $0.engine == engine && $0.speaks == nil } ?? all[0]
    }

    /// The round mark: its colour with two letters, as TablePlus draws them (too small to read under 16 pt: none).
    @MainActor func badge(_ size: CGFloat) -> NSImage {
        nonisolated(unsafe) let text = NSAttributedString(
            string: letters,
            attributes: [
                .font: NSFont.ui(size * 0.4, weight: .semibold), .foregroundColor: dark ? NSColor.black : .white
            ])
        let fill = NSColor(hex: color) ?? .systemBlue
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            guard size >= 16 else { return true }
            let fit = text.size()
            text.draw(at: NSPoint(x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2))
            return true
        }
    }
}

/// A preset's tile in Add Database's grid: its round mark over its name (and what Kelp opens it as).
@MainActor
final class EngineTile: PointerControl {
    let preset: EnginePreset

    init(_ preset: EnginePreset, action: @escaping () -> Void) {
        self.preset = preset
        super.init(frame: .zero)
        onClick = action
        layer?.cornerRadius = Metrics.radiusLG
        let mark = NSImageView(image: preset.badge(36))
        let name = NSTextField(labelWithString: preset.name)
        name.font = .ui(TextSize.caption)
        name.alignment = .center
        var views: [NSView] = [mark, name]
        if let speaks = preset.speaks {
            let under = NSTextField(labelWithString: speaks)
            under.font = .ui(TextSize.micro)
            under.textColor = .tertiaryLabelColor
            views.append(under)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = Metrics.lineGap + 1
        stack.edgeInsets = NSEdgeInsets(top: Metrics.gapWide, left: 2, bottom: Metrics.gap, right: 2)
        pin(stack)
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 82).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(preset.name)
        toolTip = preset.hint ?? preset.name
    }
    required init?(coder: NSCoder) { fatalError() }
}
