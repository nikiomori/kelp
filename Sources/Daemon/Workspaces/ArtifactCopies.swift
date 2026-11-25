import Core
import Foundation

// Kelp's copies of pages on a service, whole enough to open without the network: the files `publish_files` sent
// beside the page, the files the agent uploaded (`upload_asset`, kept by their id in the project's `.blobs`), and the
// copy that links them from the page's own folder (`offline.html`), which a preview tab may read.

extension Artifacts {
    /// The copy a preview tab opens without the network.
    static let offlineCopy = "offline.html"
    /// Names in an artifact's folder that are Kelp's own: a file the agent sent under one of them isn't kept.
    private static let ownNames: Set<String> = [
        "artifact.json", pageCopy, offlineCopy, ArtifactMarks.file, "versions", "_blob", "boards"
    ]

    /// Keeps the files sent beside a page (`PublishedPage.others`) in its folder, where they are served from. A path
    /// that climbs out of the folder, starts with a dot or takes one of Kelp's names is left out, and so is a file
    /// over 16 MB.
    static func keepOthers(_ others: [String: String], in folder: URL) throws {
        for (served, path) in others {
            let parts = served.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !served.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }),
                !ownNames.contains(parts[0]), let data = small(path, limit: 16 << 20)
            else { continue }
            let to = parts.reduce(folder) { $0.appendingPathComponent($1) }
            let parent = to.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: to, options: .atomic)
        }
    }

    /// Keeps the files an agent uploaded, by their id, in the project's `.blobs`. Returns how many it kept.
    static func keepAssets(_ assets: [ArtifactKeepAssets.Asset], root: String) throws -> Int {
        let blobs = blobs(root: root)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        var kept = 0
        for asset in assets where asset.id.allSatisfy({ $0.isLetter || $0.isNumber }) {
            guard let data = small(asset.path) else { continue }
            try data.write(to: blobs.appendingPathComponent(asset.id), options: .atomic)
            kept += 1
        }
        return kept
    }

    /// Writes the copy that opens without the network beside a page's copy: the uploaded files it uses copied into its
    /// folder (`_blob/<id>`), and its links to them made relative. Returns that file.
    static func offline(folder: URL, root: String) throws -> URL {
        let page = folder.appendingPathComponent(pageCopy)
        guard let data = small(page.path) else { throw RPCError.invalidParams("no copy of this page on this Mac") }
        let text = String(decoding: data, as: UTF8.self)
        let blobs = blobs(root: root), local = folder.appendingPathComponent("_blob")
        for id in uses(of: text).blobs {
            let from = blobs.appendingPathComponent(id), to = local.appendingPathComponent(id)
            guard fileStat(to.path) == nil, let bytes = small(from.path) else { continue }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try bytes.write(to: to, options: .atomic)
        }
        let linked = text.replacing(/(["'(=\s])\/_blob\//) { "\($0.output.1)_blob/" }
        let copy = folder.appendingPathComponent(offlineCopy)
        try Data(linked.utf8).write(to: copy, options: .atomic)
        return copy
    }
}

extension ArtifactKeepAssets: Handled {
    static let agents = AgentAccess.acts
    /// An agent's hook waits for this call to answer.
    static var quick: Bool { true }
    var fence: Fence { Fence(writesInFolder: cwd) }
    func handle(_ store: Store) throws -> Int {
        try Artifacts.keepAssets(assets, root: try artifactsRoot(store, cwd: cwd, session: session))
    }
}

extension ArtifactOffline: Handled {
    var fence: Fence { Fence(writesInFolder: folder) }
    func handle(_: NoService) throws -> String {
        let dir = URL(fileURLWithPath: folder).standardizedFileURL
        let artifacts = dir.deletingLastPathComponent()
        guard artifacts.path.hasSuffix("/" + Artifacts.folder), Artifacts.record(in: dir)?.url != nil else {
            throw RPCError.invalidParams("not the folder of a page on a service: \(folder)")
        }
        let root = artifacts.deletingLastPathComponent().deletingLastPathComponent().path
        return try Artifacts.offline(folder: dir, root: root).path
    }
}
