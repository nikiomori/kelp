import Foundation

extension Artifacts {
    /// The most tags a page keeps, and the longest a tag is.
    static let mostTags = 12, longestTag = 40

    /// Returns a tag as pages keep it: lower case, words joined by dashes, without a leading `#`. nil for nothing left.
    public static func tag(_ word: String) -> String? {
        let words = word.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "#" }.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," }).joined(separator: "-")
        return words.isEmpty ? nil : String(words.prefix(longestTag))
    }

    /// Returns `record` after a change (`ArtifactChange`): tags added and removed, the archive set, at `now`. An
    /// agent's change (with its `session`) keeps what the page had before, unless that agent's earlier change is
    /// still to undo: then the earlier state stays, so one Undo puts back the page as the user last left it. A change
    /// by the user forgets the agent's. `undo` puts back what an agent's change kept.
    public static func changed(
        _ record: ArtifactRecord, add: [String], remove: [String], archived: Bool?, session: String?, undo: Bool,
        now: Date
    ) -> ArtifactRecord {
        var next = record
        if undo {
            guard let before = record.agentChange else { return record }
            next.tags = before.tags
            next.archived = before.archived
            next.agentChange = nil
            return next
        }
        let removed = Set(remove.compactMap(tag))
        var tags = (record.tags ?? []).filter { !removed.contains($0) }
        for word in add.compactMap(tag) where !tags.contains(word) && tags.count < mostTags { tags.append(word) }
        next.tags = tags.isEmpty ? nil : tags
        if let archived { next.archived = archived ? true : nil }
        guard next.tags != record.tags || next.archived != record.archived else { return record }
        if let session {
            let kept = record.agentChange?.session == session ? record.agentChange : nil
            next.agentChange = ArtifactAgentChange(
                session: session, at: now.timeIntervalSince1970, tags: kept?.tags ?? record.tags,
                archived: kept?.archived ?? record.archived)
        } else {
            next.agentChange = nil
        }
        return next
    }
}
