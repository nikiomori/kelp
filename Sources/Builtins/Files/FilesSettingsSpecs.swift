import AppKit
import Core
import DesignKit
import KelpKit

extension Builtins {
    /// Settings › Editor.
    static var editorSettings: SettingsSection {
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
                    "⌘S runs Format Document first, for languages that have a formatter.",
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
                    requires: SettingKeys.lsp.key),
                s(
                    SettingKeys.markdownMode, "Default Markdown mode", .enum,
                    options: ["preview", "edit", "split"], look: .segments, group: "Markdown")
            ], order: 70, previews: ["": SettingSamples.editor])
    }
}

/// Settings › Editor's rows only the editor reads (the shell's are `SettingKeys` in Core).
extension SettingKeys {
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
    /// A language server's own `options` and `settings`, by its command: `{ "gopls": { "settings": { … } } }`.
    static let languageServers = Setting("editor.languageServers", JSONValue.object([:]))
    static let hover = Setting("editor.hover", true)
}
