import Core
import DesignKit
import Foundation

/// Installing and removing extensions: from a .vsix or a folder, from GitHub, to the Trash. Each ends in a reload.
extension ExtensionRegistry {
    /// Like VS Code's "Install from VSIX…": a .vsix (a zip with the extension in `extension/`) or an extension folder,
    /// copied into ~/.kelp/extensions. A version already there goes to the Trash. One with a Kelp manifest (it can run
    /// commands) is installed once the user has seen what it runs, as one from GitHub.
    func install(_ src: URL) async throws {
        let app = self.app, dir = Self.userDir, fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let (folder, name) = try await Task.detached { @Sendable () async throws -> (URL, String) in
            let fm = FileManager.default
            guard src.pathExtension.lowercased() == "vsix" else { return (src, src.lastPathComponent) }
            let unzip = await Shell.exec(app, ["/usr/bin/ditto", "-x", "-k", src.path, tmp.path])
            let folder = tmp.appendingPathComponent("extension")
            guard unzip.code == 0, fm.fileExists(atPath: folder.appendingPathComponent("package.json").path) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: src.path])
            }
            let package = folder.appendingPathComponent("package.json")
            let name = (try? JSONDecoder().decode(VSCodePackage.self, from: Data(contentsOf: package)))?.manifest.id
            return (folder, name ?? src.deletingPathExtension().lastPathComponent)
        }.value
        let shown = ExtensionFiles.extensionFiles(folder)
        if shown["/extension.json"] != nil {
            guard await ExtensionReview.approve(folder, manifest: ExtensionTrust.manifest(shown)) else { return }
        }
        let installed = try await Task.detached { try ExtensionFiles.installExtension(folder, as: name, in: dir) }.value
        _ = await ExtensionTrust.allow(installed.lastPathComponent, shown: shown, app)   // what the user just looked at
        reload()
    }

    /// From GitHub (the library's `source`, or any GitHub folder): downloaded, then installed once the user has seen what
    /// it runs. False when they said no or it failed (a banner says why).
    /// `files`: the library's SHA-256 of each, which the download must match.
    func install(source: String, files: [String: String]? = nil) async -> Bool {
        guard let fetched = await app.call(ExtensionFetch(source: source, files: files)) else { return false }
        let folder = URL(fileURLWithPath: fetched.folder), dir = Self.userDir, shown = ExtensionFiles.extensionFiles(folder)
        guard await ExtensionReview.approve(folder, manifest: ExtensionTrust.manifest(shown)) else {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
        let installed: URL
        do {
            installed = try await Task.detached {
                try ExtensionFiles.installExtension(folder, as: folder.lastPathComponent, in: dir, move: true)
            }.value
        } catch {
            Banner.show(
                String(localized: "Couldn't install \(folder.lastPathComponent): \(AppModel.message(error))"),
                style: .error)
            return false
        }
        _ = await ExtensionTrust.allow(installed.lastPathComponent, shown: shown, app)
        reload()
        return true
    }

    func uninstall(_ id: String) {
        guard let ext = extensions.first(where: { $0.id == id }), let path = ext.path, !ext.builtin else { return }
        do { try FileManager.default.trashItem(at: path, resultingItemURL: nil) } catch {
            let why = error.localizedDescription
            Banner.show(String(localized: "Couldn't move \(ext.name) to the Trash: \(why)"), style: .error)
        }
        reload()
    }
}
