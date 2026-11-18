import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension Builtins {
    /// Settings › Editor › Code suggestions: on or off per language; the list above them picks the model, and the
    /// three rows it stands for stay for search and settings.json.
    private static var suggestionRows: [SettingSpec] {
        [
            s(
                SettingKeys.suggestions, "Suggest code as you type", .enum,
                "Gray text after the cursor from a model on this Mac or in the cloud; ⇥ puts it in.",
                options: ["off", "local", "cloud"],
                labels: ["off": "Off", "local": "On This Mac", "cloud": "In the Cloud"],
                group: "Code suggestions", perLanguage: true),
            s(
                SettingKeys.suggestionCloud, "Cloud provider", .enum,
                "The code around the cursor goes to it. Its key is kept in your login keychain.",
                options: SuggestCloud.allCases.map(\.rawValue),
                labels: [
                    "mercury": "Mercury Edit 2 (Inception)", "codestral": "Codestral (Mistral)",
                    "openai": "OpenAI-Compatible Server"
                ], group: "Code suggestions", hidden: true, requires: "\(SettingKeys.suggestions.key)=cloud"),
            s(
                SettingKeys.suggestionURL, "Server address", .string,
                "Empty: the provider's own. Codestral's free key works at https://codestral.mistral.ai.",
                group: "Code suggestions", hidden: true, requires: "\(SettingKeys.suggestions.key)=cloud",
                placeholder: "https://api.example.com"),
            s(
                SettingKeys.suggestionModel, "Model", .string,
                "Empty: the first code model on this Mac, or the cloud provider's own.",
                group: "Code suggestions", hidden: true, requires: "\(SettingKeys.suggestions.key)!=off",
                placeholder: "qwen2.5-coder:1.5b-base")
        ]
    }

    /// Settings › Editor.
    static func editorSettings(_ app: AppModel) -> SettingsSection {
        SettingsSection(
            id: "editor", title: "Editor", icon: "doc.text",
            specs: [
                s(SettingKeys.editorFontFamily, "Font", .font, "Default: SF Mono."),
                s(SettingKeys.editorFontSize, "Font size", .number, range: [8, 40]),
                s(
                    SettingKeys.wordWrap, "Wrap long lines", .boolean,
                    "On: a long line continues on the next row instead of running past the edge.",
                    group: "Display", perLanguage: true),
                s(
                    SettingKeys.wordWrapColumn, "Wrap at column", .number,
                    "Wrapping stops here on a wide screen. 0: at the window's edge.",
                    group: "Display", requires: SettingKeys.wordWrap.key, perLanguage: true),
                s(
                    SettingKeys.wrappingIndent, "Wrapped lines continue", .enum,
                    "At the left edge, at their line's indentation, or one level past it.",
                    options: ["none", "same", "indent"], group: "Display", requires: SettingKeys.wordWrap.key),
                s(
                    SettingKeys.rulers, "Rulers at columns", .string, "Thin lines at these columns.",
                    group: "Display", placeholder: "80, 120", perLanguage: true),
                s(
                    SettingKeys.renderWhitespace, "Show whitespace", .enum,
                    "Unusual spaces, such as no-break ones, always show.",
                    options: ["none", "selection", "trailing", "all"], group: "Display", perLanguage: true),
                s(
                    SettingKeys.bracketColors, "Color brackets by depth", .boolean,
                    "Pairs come from the code, so brackets in strings stay as they are.",
                    group: "Display", perLanguage: true),
                s(
                    SettingKeys.indentGuides, "Indent guides", .boolean,
                    "Faint lines at each level; the block around the cursor's is brighter.",
                    group: "Display", perLanguage: true),
                s(
                    SettingKeys.breadcrumbs, "Breadcrumbs", .boolean,
                    "The file's folders and the scopes around the cursor, in a thin bar over the editor.",
                    group: "Display", perLanguage: true),
                s(
                    SettingKeys.stickyScroll, "Keep the enclosing scopes at the top", .boolean,
                    "The lines that open the class and function you're in stay pinned as you scroll.",
                    group: "Display", perLanguage: true),
                s(
                    SettingKeys.tabSize, "Tab size", .number,
                    "Spaces to a level. A file's own indentation and its .editorconfig come first.",
                    group: "Indentation", perLanguage: true),
                s(
                    SettingKeys.insertSpaces, "Indent with spaces", .boolean, group: "Indentation",
                    perLanguage: true),
                s(
                    SettingKeys.detectIndentation, "Detect indentation from the file", .boolean,
                    group: "Indentation", perLanguage: true),
                s(
                    SettingKeys.autoSave, "Save automatically", .boolean,
                    "Files save a moment after you stop typing.",
                    help:
                        "Off: edited files show a dot and you save with ⌘S. On: they save a moment after you stop typing.",
                    group: "Saving"),
                s(
                    SettingKeys.formatOnSave, "Format on save", .boolean,
                    "Saving runs Format Document first, for languages that have a formatter.",
                    group: "Saving", perLanguage: true),
                s(
                    SettingKeys.trimTrailingWhitespace, "Trim trailing whitespace on save", .boolean,
                    group: "Saving"),
                s(
                    SettingKeys.insertFinalNewline, "End files with a newline on save", .boolean,
                    group: "Saving"),
                s(
                    SettingKeys.lsp, "Use language servers", .boolean, "Completion and jump to definition.",
                    group: "Language servers"),
                s(
                    SettingKeys.hover, "Show what the language server knows on hover", .boolean,
                    "A symbol's signature and documentation, and the arguments of a call as you type it.",
                    group: "Language servers",
                    requires: SettingKeys.lsp.key)
            ] + suggestionRows + [
                s(
                    SettingKeys.markdownMode, "Default Markdown mode", .enum,
                    options: ["preview", "edit", "split"], look: .segments, group: "Markdown")
            ], order: 70,
            previews: [
                "": EditorSample.card,
                "Code suggestions": { AnyView(SuggestionsList(suggestions: Suggestions.of(app)).padding(.bottom, 8)) }
            ])
    }
}

/// The Settings › Editor rows that only the editor reads (the shell's rows are `SettingKeys` in Core).
extension SettingKeys {
    static let rulers = Setting("editor.rulers", "")
    static let renderWhitespace = Setting("editor.renderWhitespace", "selection")
    static let bracketColors = Setting("editor.bracketColors", false)
    static let indentGuides = Setting("editor.indentGuides", false)
    static let wordWrapColumn = Setting<Double>("editor.wordWrapColumn", 0)
    static let breadcrumbs = Setting("editor.breadcrumbs", false)
    static let stickyScroll = Setting("editor.stickyScroll", true)
    static let tabSize = Setting<Double>("editor.tabSize", 4)
    static let insertSpaces = Setting("editor.insertSpaces", true)
    static let detectIndentation = Setting("editor.detectIndentation", true)
    static let autoSave = Setting("editor.autoSave", false)
    static let formatOnSave = Setting("editor.formatOnSave", false)
    static let trimTrailingWhitespace = Setting("files.trimTrailingWhitespace", false)
    static let insertFinalNewline = Setting("files.insertFinalNewline", false)
    static let lsp = Setting("editor.lsp", true)
    static let hover = Setting("editor.hover", true)
    static let suggestions = Setting("editor.suggestions", "off")
    static let suggestionModel = Setting("editor.suggestionModel", "")
    static let suggestionCloud = Setting("editor.suggestionCloud", "mercury")
    static let suggestionURL = Setting("editor.suggestionURL", "")
}
