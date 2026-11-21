import Core
import Foundation

/// How the Work panel and the Map tab put a place into words: in a row's grey detail, a tooltip, and for VoiceOver.
enum WorkWords {
    /// "read 6×", "read", "searched", or nothing for a file whose edit says enough.
    static func reads(_ place: AgentWork.Place) -> String {
        if place.kind == .folder { return String(localized: "searched") }
        if place.reads > 1 { return String(localized: "read \(place.reads)×") }
        return place.reads == 1 && place.edits == 0 ? String(localized: "read") : ""
    }

    /// "+18 −5", or "" for a place nothing was written to.
    static func lines(_ place: AgentWork.Place) -> String {
        [place.added > 0 ? "+\(place.added)" : nil, place.removed > 0 ? "−\(place.removed)" : nil].compactMap { $0 }
            .joined(separator: " ")
    }

    /// A whole sentence for one node: what it is, what was done, by whom.
    static func describe(_ node: WorkNode, agents: [String]) -> String {
        var parts = [node.name]
        if let place = node.place {
            if place.edits > 0 || place.byCommand {
                let lines = lines(place)
                parts.append(
                    place.byCommand && place.edits == 0
                        ? String(localized: "changed by a command \(lines)") : String(localized: "edited \(lines)"))
            }
            let read = reads(place)
            if !read.isEmpty { parts.append(read) }
            if let worktree = place.worktree { parts.append(String(localized: "in worktree \(worktree)")) }
        } else {
            let files = node.files.count
            parts.append(String(localized: "\(files) files"))
            let edited = node.files.filter(\.edited).count
            if edited > 0 { parts.append(String(localized: "\(edited) edited")) }
            if node.searched { parts.append(String(localized: "searched")) }
        }
        let who = node.agents.sorted().compactMap { agents.indices.contains($0) ? agents[$0] : nil }
        if !who.isEmpty { parts.append(who.formatted(.list(type: .and))) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
    }
}
