import AppKit
import Core

/// The look before an extension from GitHub goes in: what it can run on this Mac, in a sheet. And the same look before
/// one that's there (written by an agent, changed since) runs anything (`ExtensionTrust`).
@MainActor
enum ExtensionReview {
    static func approve(_ folder: URL, allowing: Bool = false) async -> Bool {
        let manifest = ExtensionTrust.manifest(folder)
        let (commands, pages) = IDE.commandsIn(manifest)
        let lines = commands + pages.map { String(localized: "\($0) — a web page, which can run any command") }
        let name = manifest["name"]?.string ?? folder.lastPathComponent
        let a = NSAlert()
        a.messageText = allowing ? String(localized: "Allow “\(name)” to run commands?") : String(localized: "Install “\(name)”?")
        a.informativeText = lines.isEmpty ? String(localized: "It runs no commands.")
            : allowing ? String(localized: "It's new or changed since it was allowed. It can run these commands on this Mac:")
            : String(localized: "It can run these commands on this Mac:")
        a.addButton(withTitle: allowing ? String(localized: "Allow") : String(localized: "Install"))
        a.addButton(withTitle: allowing ? String(localized: "Not Now") : String(localized: "Cancel"))
        if !lines.isEmpty { a.accessoryView = list(lines) }
        return await runSheet(a) == .alertFirstButtonReturn
    }

    private static func list(_ lines: [String]) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: min(220, CGFloat(lines.count) * 17 + 10))
        scroll.borderType = .bezelBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.string = lines.joined(separator: "\n")
            tv.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 4, height: 4)
        }
        return scroll
    }
}

/// An extension in ~/.kelp/extensions runs commands (its own, its events, its pages) only once the user allowed it as its
/// files are now: an agent writes these folders, and what one wrote shouldn't run as the user without their look. The
/// daemon checks the same before it runs any (`Sessions.trustsExtension`); here it's what's loaded and asked.
@MainActor
enum ExtensionTrust {
    static func manifest(_ folder: URL) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent("extension.json")))) ?? .null
    }

    /// Whether `folder`'s extension waits to be allowed: it runs something, and what was allowed isn't what's there. Not
    /// before the daemon's state is in (the daemon refuses meanwhile), nor before the window ever recorded one (`adopt`).
    static func waits(_ folder: URL, _ app: AppModel) -> Bool {
        guard app.connected, case .object(let allowed)? = app.uiState[IDE.trustKey] else { return false }
        let (commands, pages) = IDE.commandsIn(manifest(folder))
        guard !commands.isEmpty || !pages.isEmpty else { return false }
        return allowed[folder.lastPathComponent]?.string != IDE.extensionDigest(folder)
    }

    /// Allowed as `folders` are now. False when it couldn't be recorded (a banner says why).
    static func allow(_ folders: [URL], _ app: AppModel) async -> Bool {
        await record(Dictionary(folders.map { ($0.lastPathComponent, IDE.extensionDigest($0)) }) { a, _ in a }, app)
    }

    /// The look, and allowed as it was when shown: a change made while the sheet was up is asked about again.
    static func review(_ folder: URL, _ app: AppModel) async -> Bool {
        let shown = IDE.extensionDigest(folder)
        guard await ExtensionReview.approve(folder, allowing: true) else { return false }
        return await record([folder.lastPathComponent: shown], app)
    }

    private static func record(_ digests: [String: String], _ app: AppModel) async -> Bool {
        guard app.connected else { return false }
        var allowed: [String: JSONValue] = [:]
        if case .object(let was)? = app.uiState[IDE.trustKey] { allowed = was }
        for (name, d) in digests { allowed[name] = .string(d) }
        return await app.uiState.save(IDE.trustKey, .object(allowed))
    }

    /// The first time this Kelp sees the daemon's state without the key: what's installed was installed when nothing was
    /// asked, so it's allowed as it is; from now on a new or changed one is asked about.
    static func adopt(_ folders: [URL], _ app: AppModel) async -> Bool {
        guard app.connected, app.uiState[IDE.trustKey] == nil else { return false }
        return await allow(folders, app)
    }
}
