import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import SwiftUI

/// The real editor, read-only, on a few lines of Swift, over Settings › Editor's rows: font, colors, wrapping, rulers,
/// whitespace, brackets and guides as those rows set them for every language (`FileRules.applyLooks`, as a file's tab).
struct EditorSample: NSViewRepresentable {
    @Environment(AppModel.self) private var app

    /// As a section's preview: framed like the terminal's.
    static func card() -> AnyView {
        AnyView(
            EditorSample().frame(height: 132).clipShape(
                RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).strokeBorder(
                    Color.primary.opacity(0.12))))
    }

    private static let sample = """
        struct Agent {
            let name: String
            func greet(_ people: [String]) -> String {
                let line = people.map { "Hello, \\($0)! \\(name) has three agents waiting, and one asks to run npm test" }
                return line.joined(separator: "\\n")  \u{20}
            }
        }
        """

    func makeCoordinator() -> CodeEditor {
        CodeEditor(text: Self.sample, url: URL(fileURLWithPath: "/sample.swift"), editable: false)
    }
    func makeNSView(context: Context) -> NSView { context.coordinator.view }

    func updateNSView(_ view: NSView, context: Context) {
        let editor = context.coordinator
        _ = app.themes.editorRevision   // font, colors and wrapping are the editor's own (ThemeManager sets them)
        FileRules.applyLooks(to: editor, app.settings, language: nil)
        // A moment later: ThemeManager applies a settings change after the views that read it are told.
        DispatchQueue.main.async { editor.refreshAppearance() }
    }
}
