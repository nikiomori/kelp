import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// Paths agents print, made useful: ⌘-click opens them (on their line), resting the pointer on one shows the file —
/// the changed lines when it has changes, the lines around the one named, or the picture.
@MainActor
enum TerminalPaths {
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg", "ico"]

    /// "Sources/App.swift:12:5", "~/x.md", "a/src/x.ts" (a diff's) → an existing file and its line, from `cwd` — or from
    /// the one folder of `elsewhere` (the other projects) that has it: an agent may name another project's files.
    static func resolve(_ token: String, cwd: String, elsewhere: [String] = []) -> (path: String, line: Int?)? {
        guard !token.contains("://") || token.hasPrefix("file://") else { return nil }   // URLs are Ghostty's
        var text = token.hasPrefix("file://") ? (URL(string: token)?.path ?? token) : token
        while let trailing = text.last, ".:;!?".contains(trailing) { text.removeLast() }   // Ghostty's links take the "." that ends a sentence
        if text.hasPrefix("@") { text.removeFirst() }   // "@src/x.ts" (an agent's mention)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let line = parts.count > 1 ? Int(parts[1]) : nil
        let raw = (String(parts[0]) as NSString).expandingTildeInPath
        guard raw.contains("/") || raw.contains(".") else { return nil }   // a word, not a path
        for candidate in [raw, raw.hasPrefix("a/") || raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : nil].compactMap({
            $0
        }) {
            if let existing = file(candidate, in: cwd) { return (existing, line) }
        }
        let found = raw.hasPrefix("/") ? [] : Set(elsewhere.compactMap { file(raw, in: $0) })
        return found.count == 1 ? found.first.map { ($0, line) } : nil   // in two projects: which one is anyone's guess
    }

    /// A file: not a folder, nor a pipe or device (reading one to preview it would block).
    private static func file(_ path: String, in dir: String) -> String? {
        let abs = path.hasPrefix("/") ? path : (dir as NSString).appendingPathComponent(path)
        var st = stat()
        return stat(abs, &st) == 0 && st.st_mode & S_IFMT == S_IFREG ? (abs as NSString).standardizingPath : nil
    }

    /// ⌘-click: in Kelp, on its line (the tab it's already in, if any); ⌥⌘-click: shown in the Finder. Not opened with its
    /// app: a program printed the path, and a .command file (or any script) would run there — from a cloned repo,
    /// without Gatekeeper's check.
    static func open(
        _ token: String, cwd: String, elsewhere: [String] = [], workspace: String? = nil, flags: NSEvent.ModifierFlags,
        in app: AppModel
    ) -> Bool {
        guard let found = resolve(token, cwd: cwd, elsewhere: elsewhere) else {
            return openOnHost(token, cwd: cwd, workspace: workspace, in: app)
        }
        if flags.contains(.option) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found.path)])
            return true
        }
        app.workbench.open(TabURI.file(found.path) + (found.line.map { "#L\($0)" } ?? ""))
        return true
    }
}

extension TerminalPaths {
    /// In a remote project's terminal a path names the host's file: from its folder there, or by its path on the host.
    /// Opened once the project lists it (asked of the host: a click may), its tab read from there. Never hovered: the
    /// preview reads the file here.
    static func openOnHost(_ token: String, cwd: String, workspace: String?, in app: AppModel) -> Bool {
        guard let workspace, let remote = RemoteHost.of(cwd), let (path, line) = onHost(token, root: remote.path)
        else { return false }
        let uri = TabURI.file(cwd + "/" + path) + (line.map { "#L\($0)" } ?? "")
        Task {
            guard await app.quiet(FilesList(id: workspace))?.contains(path) == true else {
                return Banner.show(String(localized: "No file “\(path)” in \(remote.host):\(remote.path)."))
            }
            app.workbench.open(uri)
        }
        return true
    }

    /// A token as a path in the project whose folder is `root` on its host, from that folder: one relative to it (a
    /// diff's "a/…" too) or under it; nil for a word, a path elsewhere, or one that climbs out.
    static func onHost(_ token: String, root: String) -> (path: String, line: Int?)? {
        var text = token.hasPrefix("file://") ? (URL(string: token)?.path ?? token) : token
        while let trailing = text.last, ".:;!?".contains(trailing) { text.removeLast() }
        if text.hasPrefix("@") { text.removeFirst() }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let line = parts.count > 1 ? Int(parts[1]) : nil
        var path = String(parts.first ?? "")
        if path.hasPrefix(root + "/") {
            path.removeFirst(root.count + 1)
        } else if path.hasPrefix("/") || path.hasPrefix("~") {
            return nil
        } else if path.hasPrefix("a/") || path.hasPrefix("b/") {
            path.removeFirst(2)
        }
        var kept: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part != ".." {
                kept.append(part)
            } else if kept.popLast() == nil {
                return nil   // out of the project
            }
        }
        path = kept.joined(separator: "/")
        guard path.contains("/") || path.contains(".") else { return nil }   // a word, not a path
        return (path, line)
    }

    /// A file of a remote project, dropped on a terminal: its path on the host, which is what a program there can open.
    static func onHost(_ path: String) -> String { Remotes(home: Paths.root).containing(path)?.remotePath ?? path }
}

/// The popover the terminal shows for a path under the pointer.
@MainActor
final class PathPreview {
    private let app: AppModel
    private let popover = NSPopover()
    init(app: AppModel) {
        self.app = app
        popover.behavior = .semitransient
        popover.animates = false
    }

    /// The first of `tokens` (what the word under the pointer may be) that is a file; none closes it.
    func show(_ tokens: [String], rect: NSRect, in view: NSView, cwd: String, worktree: String?) {
        let projects = app.repos.map(\.path)
        guard let found = tokens.lazy.compactMap({ TerminalPaths.resolve($0, cwd: cwd, elsewhere: projects) }).first
        else {
            popover.close()
            return
        }
        let model = PreviewModel(path: found.path, line: found.line, cwd: cwd, app: app)
        let host = NSHostingController(rootView: PathPreviewView(model: model))
        host.sizingOptions = .preferredContentSize   // placed and resized around the anchor (see HoverCard)
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        model.load(worktree: worktree)
    }
}

@MainActor
@Observable
final class PreviewModel {
    struct Line: Identifiable {   // mark: + - or space
        let id: Int
        let number: Int?
        let text: String
        let mark: Character
    }
    let path: String, line: Int?, name: String, folder: String
    var lines: [Line] = []
    var image: NSImage?
    var changed = false
    private let app: AppModel

    init(path: String, line: Int?, cwd: String, app: AppModel) {
        self.path = path
        self.line = line
        self.app = app
        name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent, root = (cwd as NSString).standardizingPath   // both without /private
        folder =
            dir.hasPrefix(root + "/")
            ? String(dir.dropFirst(root.count + 1)) : dir == root ? "" : (dir as NSString).abbreviatingWithTildeInPath
    }

    func load(worktree: String?) {
        if TerminalPaths.images.contains((path as NSString).pathExtension.lowercased()) {
            image = NSImage(contentsOfFile: path)
            return
        }
        lines = excerpt()
        guard let worktree else { return }
        Task {
            // Uncommitted changes in it: show those (the hunk with the line asked about, else the first).
            let diff = await app.quiet(GitDiff(id: worktree, source: "all", file: path))
            guard let hunks = diff?.first?.hunks, !hunks.isEmpty else { return }
            let hunk =
                hunks.first { hunk in line.map { l in hunk.lines.contains { $0.newLine == l } } ?? false } ?? hunks[0]
            changed = true
            lines = hunk.lines.prefix(16).enumerated().map { index, diffLine in
                Line(
                    id: index, number: diffLine.newLine ?? diffLine.oldLine, text: diffLine.text,
                    mark: diffLine.kind == .add ? "+" : diffLine.kind == .del ? "-" : " ")
            }
        }
    }

    /// Up to 14 lines around the line named (or the file's first), read from at most 256 KB of it.
    private func excerpt() -> [Line] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 262_144)) ?? Data()
        guard !data.contains(0) else {
            return [Line(id: 0, number: nil, text: String(localized: "Binary file"), mark: " ")]
        }
        let all = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let start = max(0, (line ?? 1) - 5)
        return all.indices.dropFirst(start).prefix(14).map { Line(id: $0, number: $0 + 1, text: all[$0], mark: " ") }
    }
}

struct PathPreviewView: View {
    let model: PreviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.name).font(.ui(TextSize.body, weight: .semibold))
                if !model.folder.isEmpty {
                    Text(model.folder).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if model.changed {
                    Text("Changed").font(.ui(TextSize.caption, weight: .medium)).foregroundStyle(Color.textOrange)
                }
            }
            if let img = model.image {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 240)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(
                                width: 34, alignment: .trailing)
                            Text(line.mark == " " ? line.text : "\(line.mark) \(line.text)").lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    line.mark == "+" ? Color.textGreen : line.mark == "-" ? Color.textRed : .primary)
                        }
                        .padding(.vertical, 1)
                        .background(
                            line.number == model.line && line.mark == " "
                                ? Color(nsColor: .fillTint(.controlAccentColor)) : .clear)
                    }
                }
                .font(.uiMono(TextSize.caption))
            }
            Text("⌘-click to open · ⌥⌘-click opens it in its app").font(.ui(TextSize.caption)).foregroundStyle(
                .tertiary)
        }
        .padding(12).frame(width: 520, alignment: .leading)
    }
}
