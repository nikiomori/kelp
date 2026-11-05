import AppKit
import SwiftUI
import DesignKit
import EditorKit

/// Over a group of rows, what they change, drawn with the settings as they are: the terminal, the editor, the sidebar's
/// plan limits. It follows each change at once, so a row is tried by looking up.
struct SettingPreview: View {
    let section: String
    let group: String?

    var body: some View {
        switch (section, group) {
        case ("terminal", nil): TerminalSample()
        case ("editor", nil): EditorSample().frame(height: 132).clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
        case ("agents", "Plan limits"): LimitsSample()
        default: EmptyView()
        }
    }
}

/// A prompt and a command in the terminal's font, size, colors and cursor. Ghostty draws the real one; this is text in the
/// same font, so its cell spacing can differ a little.
private struct TerminalSample: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.settings, colors = app.themes.shown?.terminal
        let size = CGFloat(s.number("terminal.fontSize") ?? 13)
        let font = s.string("terminal.fontFamily").flatMap { NSFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let fg = colors.flatMap { NSColor(hex: $0.foreground) }.map(Color.init) ?? .primary
        let palette = colors?.palette ?? []
        let tint = { (i: Int) in palette.count > i ? NSColor(hex: palette[i]).map(Color.init) ?? fg : fg }
        VStack(alignment: .leading, spacing: 2) {
            (Text(verbatim: "~/projects/kelp ").foregroundStyle(tint(4)) + Text(verbatim: "main").foregroundStyle(tint(2)))
            HStack(spacing: 0) {
                Text(verbatim: "❯ swift build ").foregroundStyle(fg)
                cursor(size).foregroundStyle(Color(nsColor: colors?.cursor.flatMap { NSColor(hex: $0) } ?? .controlAccentColor))
            }
        }
        .font(Font(font))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.inset)
        .background(Color(nsColor: app.themes.terminalBackground), in: RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cursor(_ size: CGFloat) -> some View {
        switch app.settings.string("terminal.cursorStyle") {
        case "bar": Rectangle().frame(width: 2, height: size * 1.25)
        case "underline": Rectangle().frame(width: size * 0.6, height: 2).frame(height: size * 1.25, alignment: .bottom)
        default: Rectangle().frame(width: size * 0.6, height: size * 1.25)
        }
    }
}

/// The real editor, read-only, on a few lines of Swift: font, colors, wrapping, rulers, whitespace, brackets and guides as
/// the rows below set them for every language.
private struct EditorSample: NSViewRepresentable {
    @Environment(AppModel.self) private var app

    private static let sample = """
    struct Agent {
        let name: String
        func greet(_ people: [String]) -> String {
            let line = people.map { "Hello, \\($0)! \\(name) has three agents waiting, and one asks to run npm test" }
            return line.joined(separator: "\\n")  \u{20}
        }
    }
    """

    func makeCoordinator() -> CodeEditor { CodeEditor(text: Self.sample, url: URL(fileURLWithPath: "/sample.swift"), editable: false) }
    func makeNSView(context: Context) -> NSView { context.coordinator.view }

    func updateNSView(_ view: NSView, context: Context) {
        let e = context.coordinator, s = app.settings
        _ = app.themes.editorRevision   // font, colors and wrapping are the editor's own (ThemeManager sets them)
        e.rulers = s.string("editor.rulers").map { $0.split { !$0.isNumber }.compactMap { Int($0) }.filter { $0 > 0 } } ?? []
        e.whitespace = EditorTextView.WhitespaceMarks(rawValue: s.string("editor.renderWhitespace") ?? "") ?? .selection
        e.bracketColors = s.bool("editor.bracketColors") == true
        e.indentGuides = s.bool("editor.indentGuides") == true
        // A moment later: ThemeManager applies a settings change after the views that read it are told.
        DispatchQueue.main.async { e.refreshAppearance() }
    }
}

/// The sidebar's foot as it is, with this Mac's real readings: the rows below change it as they're switched.
private struct LimitsSample: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        UsageView(app: app)
            .frame(width: 250)
            .background(Color(nsColor: .fillRest), in: RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
            .frame(maxWidth: .infinity)
    }
}
