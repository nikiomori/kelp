import AppKit
import Core
import DesignKit

/// The review sheet shown before an extension from GitHub is installed, listing what it can run on this Mac. The same
/// sheet shows before an extension already in the folder (written by an agent, or changed since) runs anything
/// (`ExtensionTrust`).
@MainActor
enum ExtensionReview {
    static func approve(_ folder: URL, manifest shown: JSONValue? = nil, allowing: Bool = false) async -> Bool {
        let manifest = shown ?? ExtensionTrust.manifest(folder)
        let (commands, pages) = ExtensionFiles.commandsIn(manifest)
        let lines = commands + pages.map { String(localized: "\($0) — a web page, which can run any command") }
        let name = manifest["name"]?.string ?? folder.lastPathComponent
        let alert = NSAlert(
            question: allowing
                ? String(localized: "Allow “\(name)” to run commands?") : String(localized: "Install “\(name)”?"),
            detail: lines.isEmpty
                ? String(localized: "It runs no commands.")
                : allowing
                    ? String(
                        localized: "It's new or changed since it was allowed. It can run these commands on this Mac:")
                    : String(localized: "It can run these commands on this Mac:"),
            action: allowing ? String(localized: "Allow") : String(localized: "Install"),
            cancel: allowing ? String(localized: "Not Now") : nil)
        if !lines.isEmpty {
            alert.accessoryView = NSScrollView.readOnly(lines.joined(separator: "\n"), lines: lines.count)
        }
        return await runSheet(alert) == .alertFirstButtonReturn
    }
}

/// An extension in ~/.kelp/extensions runs commands (its own, its events', its pages') only after the user allowed its
/// files as they are now. Agents write these folders, and what an agent wrote shouldn't run as the user before the user
/// has looked at it. The daemon checks the same before it runs any command (`SessionSetup.trustsExtension`); this side
/// decides what is loaded and what the user is asked.
@MainActor
enum ExtensionTrust {
    static func manifest(_ folder: URL) -> JSONValue {
        manifest(["/extension.json": FileManager.default.contents(atPath: folder.path + "/extension.json") ?? Data()])
    }
    /// Decodes the manifest from one read of a folder (`ExtensionFiles.extensionFiles`).
    static func manifest(_ files: [String: Data]) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: files["/extension.json"] ?? Data())) ?? .null
    }

    /// Allows the folder installed as `name` as it was in `shown`, the read the review sheet listed. A file swapped
    /// between the review and the install makes Kelp ask again instead of running it.
    static func allow(_ name: String, shown: [String: Data], _ app: AppModel) async -> Bool {
        await record([name: ExtensionFiles.extensionDigest(shown)], app)
    }

    /// Whether `folder`'s extension waits to be allowed. It waits when it runs something and what was allowed isn't
    /// what's there now, or when a daemon is there but what was allowed isn't known yet (its state not read, or not
    /// readable). Without a daemon nothing of it can run anyway (the daemon checks too), and the first connection that
    /// reads the state reloads (`loadedWithoutState`). With no record at all it waits too, until `adopt` has recorded
    /// what was there before Kelp asked.
    static func waits(_ folder: URL, _ app: AppModel) -> Bool {
        let (commands, pages) = ExtensionFiles.commandsIn(manifest(folder))
        guard !commands.isEmpty || !pages.isEmpty else { return false }
        guard app.uiState.loaded else { return app.hasDaemon }
        return app.uiState[ExtensionFiles.extensionTrustKey]?[folder.lastPathComponent]?.string
            != ExtensionFiles.extensionDigest(folder)
    }

    /// Allows `folders` as they are now. Returns false when that couldn't be recorded (a banner says why).
    static func allow(_ folders: [URL], _ app: AppModel) async -> Bool {
        await record(
            Dictionary(folders.map { ($0.lastPathComponent, ExtensionFiles.extensionDigest($0)) }) { a, _ in a }, app)
    }

    /// Shows the review sheet and allows the extension as it was shown. The sheet lists what the manifest from the same
    /// read says (`ExtensionFiles.extensionFiles`), so a manifest swapped while the folder was hashed can't be shown in
    /// place of the one allowed.
    static func review(_ folder: URL, _ app: AppModel) async -> Bool {
        let files = ExtensionFiles.extensionFiles(folder), manifest: JSONValue
        do { manifest = try JSONDecoder().decode(JSONValue.self, from: files["/extension.json"] ?? Data()) } catch {
            Banner.show(
                String(
                    localized: "“\(folder.lastPathComponent)” has no manifest Kelp can read: \(AppModel.message(error))"
                ), style: .error)
            return false
        }
        guard await ExtensionReview.approve(folder, manifest: manifest, allowing: true) else { return false }
        return await record([folder.lastPathComponent: ExtensionFiles.extensionDigest(files)], app)
    }

    private static func record(_ digests: [String: String], _ app: AppModel) async -> Bool {
        guard app.connected else { return false }
        var allowed: [String: JSONValue] = [:]
        if case .object(let was)? = app.uiState[ExtensionFiles.extensionTrustKey] { allowed = was }
        for (name, d) in digests { allowed[name] = .string(d) }
        return await app.uiState.save(ExtensionFiles.extensionTrustKey, .object(allowed))
    }

    /// Runs once, the first time this Kelp sees the daemon's state without the trust key. Extensions installed before
    /// Kelp began to ask (`askedSince`) are allowed as they are, and the record, even an empty one, marks this done. An
    /// extension made since then is asked about. Returns true when an extension was allowed this way (an empty record
    /// changes nothing loaded).
    static func adopt(_ folders: [URL], _ app: AppModel) async -> Bool {
        guard app.connected, app.uiState.loaded, app.uiState[ExtensionFiles.extensionTrustKey] == nil else {
            return false
        }
        let old = folders.filter { created($0) < askedSince }
        return await allow(old, app) && !old.isEmpty
    }

    /// When Kelp began to ask (0.10, 2026-11-06 UTC).
    static let askedSince = Date(timeIntervalSince1970: 1_793_923_200)

    /// Returns when `folder` was made. A folder whose date can't be read counts as new, so the user is asked about it.
    private static func created(_ folder: URL) -> Date {
        do { return try folder.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantFuture } catch {
            return .distantFuture
        }
    }
}
