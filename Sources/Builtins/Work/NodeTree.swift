import Core
import Foundation

/// The Map tab's nodes: the agent, then its project (folders, files) and, below a line, what it reached outside. A big
/// tree is folded to about `budget` leaves, so a whole session's hundreds of files fit a screen: edited files always
/// show; a folder only read from is one node ("Builtins · 61 read") until it is opened; an edited folder shows its
/// edits and a couple of reads, the rest as "+ 5 read".
struct MapNode: Equatable {
    enum Kind: Equatable { case agent, group, folder, file, more, folded, outside }
    var id: String
    var parent: String?
    var kind: Kind
    var label: String
    /// A folder holding one file shows as one node: the folder's name in grey before the file's.
    var prefix: String?
    var detail = ""
    var place: AgentWork.Place?
    var edited = false
    var agents: [Int] = []
    /// For a folded folder or a "+ N read": the folder it opens.
    var opens: String?
}

enum NodeTree {
    /// The ids of the nodes that aren't paths: a character no path has in front, so a project's folder named `agent`,
    /// `project` or `outside` is its own node.
    static let agentId = "\u{1}agent", projectId = "\u{1}project", outsideId = "\u{1}outside"
    static func outsideId(_ place: AgentWork.Place) -> String {
        outsideId + "/" + place.kind.rawValue + "/" + place.name
    }

    static let budget = 40

    static func nodes(
        project: WorkNode, outside: [AgentWork.Place], opened: Set<String>, budget: Int = budget
    ) -> [MapNode] {
        var strict = false
        var out = build(project, outside: outside, opened: opened, strict: false)
        // Past the budget, read-only folders fold whatever their size, and edited folders keep only their edits.
        if out.filter(isLeaf).count > budget {
            strict = true
            out = build(project, outside: outside, opened: opened, strict: strict)
        }
        return out
    }

    private static func isLeaf(_ node: MapNode) -> Bool {
        [.file, .more, .folded, .outside].contains(node.kind)
    }

    private static func build(_ project: WorkNode, outside: [AgentWork.Place], opened: Set<String>, strict: Bool)
        -> [MapNode]
    {
        var out = [MapNode(id: agentId, kind: .agent, label: "")]
        // A turn that only reached outside has no project branch ("Kelp, 0 files" would say nothing).
        if !project.children.isEmpty || project.searched {
            out.append(
                MapNode(
                    id: projectId, parent: agentId, kind: .group, label: project.name,
                    detail: String(localized: "\(project.files.count) files")))
        }
        func add(_ node: WorkNode, under parent: String, depth: Int) {
            let folders = node.children.filter { !$0.isFile }, files = node.children.filter(\.isFile)
            for folder in folders {
                // A folder with one file is that file, its folder's name in front.
                if folder.children.count == 1, let only = folder.children.first, only.isFile, !folder.searched {
                    out.append(file(only, parent: parent, prefix: folder.name + "/"))
                    continue
                }
                let readOnly = !folder.edited
                if readOnly, !opened.contains(folder.path), depth >= 1 || strict, folder.files.count >= (strict ? 1 : 3)
                {
                    out.append(
                        MapNode(
                            id: folder.path, parent: parent, kind: .folded, label: folder.name,
                            detail: folder.searched && folder.files.isEmpty
                                ? String(localized: "searched") : String(localized: "\(folder.files.count) read"),
                            agents: folder.agents.sorted(), opens: folder.path))
                    continue
                }
                out.append(
                    MapNode(id: folder.path, parent: parent, kind: .folder, label: folder.name, edited: folder.edited))
                add(folder, under: folder.path, depth: depth + 1)
            }
            let edits = files.filter(\.edited), reads = files.filter { !$0.edited }
            let keep = opened.contains(node.path) ? reads.count : (edits.isEmpty ? (strict ? 0 : 3) : (strict ? 0 : 2))
            for f in edits + reads.prefix(keep) { out.append(file(f, parent: parent)) }
            if reads.count > keep {
                out.append(
                    MapNode(
                        id: node.path + "/+", parent: parent, kind: .more,
                        label: String(localized: "+ \(reads.count - keep) read"), opens: node.path))
            }
        }
        add(project, under: projectId, depth: 0)
        if !outside.isEmpty {
            out.append(
                MapNode(
                    id: outsideId, parent: agentId, kind: .group, label: String(localized: "Outside"),
                    detail: "\(outside.count)"))
            for place in outside {
                out.append(
                    MapNode(
                        id: outsideId(place), parent: outsideId, kind: .outside,
                        label: place.name,
                        detail: place.detail ?? "", place: place, agents: place.agents))
            }
        }
        return out
    }

    private static func file(_ node: WorkNode, parent: String, prefix: String? = nil) -> MapNode {
        let place = node.place
        let detail =
            place.map { [WorkWords.lines($0), WorkWords.reads($0)].filter { !$0.isEmpty }.joined(separator: " · ") }
            ?? ""
        return MapNode(
            id: node.path, parent: parent, kind: .file, label: node.name, prefix: prefix, detail: detail, place: place,
            edited: node.edited, agents: place?.agents ?? [])
    }

    /// Where each node goes: columns by depth, each as wide as its longest folder name (`width`; a file's words run on
    /// to the right on a row of their own) and a gap; leaves one `step` apart from the top, the outside's after a gap;
    /// a parent in the middle of its children.
    static func layout(_ nodes: [MapNode], width: (MapNode) -> CGFloat, step: CGFloat, gap: CGFloat) -> [String:
        CGPoint]
    {
        var children: [String: [String]] = [:], depth: [String: Int] = [:]
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for node in nodes { if let parent = node.parent { children[parent, default: []].append(node.id) } }
        func setDepth(_ id: String, _ level: Int) {
            guard depth[id] == nil else { return }   // a cycle can't be, but must not overflow the stack if it were
            depth[id] = level
            for child in children[id] ?? [] { setDepth(child, level + 1) }
        }
        setDepth(agentId, 0)
        var columns: [CGFloat] = []
        for node in nodes {
            let level = depth[node.id] ?? 0
            while columns.count <= level { columns.append(0) }
            if [.agent, .group, .folder].contains(node.kind) { columns[level] = max(columns[level], width(node)) }
        }
        var x: [CGFloat] = [0]
        for w in columns { x.append((x.last ?? 0) + w + gap) }
        var at: [String: CGPoint] = [:], y: CGFloat = 0
        func place(_ id: String) -> CGFloat {
            let kids = children[id] ?? []
            let mid: CGFloat
            if kids.isEmpty {
                mid = y
                y += step
            } else {
                let ys = kids.map(place)
                mid = ((ys.first ?? 0) + (ys.last ?? 0)) / 2
            }
            at[id] = CGPoint(x: x[min(depth[id] ?? 0, x.count - 1)], y: mid)
            return mid
        }
        for top in children[agentId] ?? [] {
            if byId[top]?.id == outsideId { y += step / 2 }
            _ = place(top)
        }
        let tops = (children[agentId] ?? []).compactMap { at[$0]?.y }
        at[agentId] = CGPoint(x: 0, y: ((tops.first ?? 0) + (tops.last ?? 0)) / 2)
        return at
    }
}
