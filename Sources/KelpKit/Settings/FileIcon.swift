import AppKit
import UniformTypeIdentifiers

/// The icon beside a file or folder name (Files, Source Control, tabs, Quick Open), from the theme picked in
/// Settings › Appearance: Colorful (symbols tinted by kind, the default: they sit with the rest of Kelp's symbols and read
/// on a light theme, where Finder's pale paper icons didn't), System (Finder's), or a VS Code icon theme an extension adds.
@MainActor
package struct FileIcon {
    let app: AppModel
    static let system = "default", colorful = "kelp.colorful"
    /// What an unset `workbench.iconTheme` means.
    static let standard = colorful

    /// The choices for `workbench.iconTheme`.
    var themes: [(id: String, label: String)] {
        [(Self.colorful, "Colorful"), (Self.system, "System")] + app.extensions.all.iconThemes.map { ($0.id, $0.label) }
    }

    /// Changes with the pick and with installed extensions: views showing icons reload when it does.
    package var revision: String { "\(app.settings.string("workbench.iconTheme") ?? Self.standard)#\(app.extensions.revision)" }

    package func image(_ name: String, folder: Bool = false, expanded: Bool = false) -> NSImage {
        switch app.settings.string("workbench.iconTheme") ?? Self.standard {
        case Self.system: Self.systemIcon(name, folder: folder)
        case Self.colorful: ColorfulIcons.image(name, folder: folder)
        case let id: contributed(id)?.image(name, folder: folder, expanded: expanded) ?? Self.systemIcon(name, folder: folder)
        }
    }

    private static var systemIcons: [String: NSImage] = [:]
    private static func systemIcon(_ name: String, folder: Bool) -> NSImage {
        if folder { return .symbol("folder") }
        let ext = (name as NSString).pathExtension.lowercased()
        if let i = systemIcons[ext] { return i }
        let i = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data).resized(16)
        systemIcons[ext] = i; return i
    }

    private static var loaded: (key: String, theme: IconTheme?)?
    private func contributed(_ id: String) -> IconTheme? {
        let key = "\(id)#\(app.extensions.revision)"
        if Self.loaded?.key != key {
            var theme: IconTheme?
            if let spec = app.extensions.all.iconThemes.first(where: { $0.id == id }) {
                do { theme = try IconTheme(contentsOf: spec.file) }
                catch { Banner.show(String(localized: "File icon theme “\(spec.label)”: \(error.localizedDescription)"), style: .error) }
            }
            Self.loaded = (key, theme)
        }
        return Self.loaded?.theme
    }
}

extension AppModel {
    /// File icons in the theme it's set to.
    package var fileIcons: FileIcon { FileIcon(app: self) }
}
