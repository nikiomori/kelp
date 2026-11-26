import AppKit
import Core
import DesignKit
import KelpKit

/// A page's kind: read from its file or the artifacts list, and its symbol and name.
extension ArtifactBar {
    /// Returns the page's kind from its file name, for use before its record is read. canvas.json counts as a design
    /// until the record says it's a dashboard.
    static func kind(ofFile path: String) -> Artifacts.Kind? {
        guard isPage(path) else { return nil }
        return Artifacts.Kind.allCases.first { path.hasSuffix("/" + $0.file) }
    }

    /// The tab's icon for a kind of page.
    static func icon(_ kind: Artifacts.Kind) -> NSImage? {
        let (symbol, name) = look(kind)
        return .symbol(symbol, name)
    }

    /// A kind of page's symbol and name, as its tab and its bar show them.
    static func look(_ kind: Artifacts.Kind) -> (symbol: String, name: String) {
        switch kind {
        case .doc: ("doc.text", String(localized: "Doc"))
        case .review: ("checklist", String(localized: "Review"))
        case .slides: ("play.rectangle", String(localized: "Slides"))
        case .design: ("square.grid.2x2", String(localized: "Design"))
        case .dashboard: ("chart.bar", String(localized: "Dashboard"))
        case .proof: ("checkmark.seal", String(localized: "Proof"))
        case .motion: ("film", String(localized: "Motion"))
        }
    }

    /// Returns a page's title and kind from the workspace's artifacts list. A tab that isn't built yet takes its name
    /// from this.
    static func listed(_ path: String, in app: AppModel) -> (title: String, kind: Artifacts.Kind)? {
        guard isPage(path) else { return nil }
        let real = Paths.real(path) ?? path
        guard let workspace = app.worktree(holding: real)?.id,
            let item = app.latest(ArtifactsEvent.self, workspace)?.items.first(where: {
                (Paths.real($0.target) ?? $0.target) == real
            }),
            !item.title.isEmpty, let kind = Artifacts.Kind(rawValue: item.type) ?? kind(ofFile: path)
        else { return nil }
        return (item.title, kind)
    }

    /// Whether `path` is a page Kelp made (`.kelp/artifacts/<name>/<kind>.md`), not one of its kept versions.
    static func isPage(_ path: String) -> Bool {
        guard let range = path.range(of: "/\(Artifacts.folder)/") else { return false }
        let rest = path[range.upperBound...].split(separator: "/")
        return rest.count == 2
            && (Artifacts.Kind.allCases.contains { $0.file == rest[1] }
                || Artifacts.olderFiles.contains(String(rest[1])) || rest[1] == Artifacts.offlineCopy)
    }
}
