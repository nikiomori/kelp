import Foundation

// YAML anchors in the files Kelp reads databases from (compose files, config/database.yml), followed as text.

extension DatabaseFind {
    /// Writes out the YAML anchors these files use: a block marked `name: &anchor` stands in for each `<<: *anchor`
    /// (its lines put where the alias is) and each `key: *anchor` (its lines put under the key). The merged lines come
    /// first, so a block's own keys after `<<:` win, as YAML's merge says. The `&anchor` marks are dropped.
    /// Limit: anchors on a block only (not on a single value), and an alias before its anchor isn't followed.
    static func expandingAnchors(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var blocks: [String: [String]] = [:], out: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if let anchored = line.wholeMatch(of: /(\s*[^\s#][^:#]*:)\s+&([\w.-]+)\s*/) {
                let top = indent(line)
                let block = lines[(index + 1)...].prefix { blank($0) || indent($0) > top }.filter { !blank($0) }
                let base = block.map(indent).min() ?? 0
                blocks[String(anchored.2)] = block.map { String($0.dropFirst(base)) }
                out.append(String(anchored.1))
            } else {
                out += aliased(line, blocks, depth: 0)
            }
        }
        return out.joined(separator: "\n")
    }

    /// The lines that `line` stands for: the anchored block's lines for an alias, else the line itself.
    private static func aliased(_ line: String, _ blocks: [String: [String]], depth: Int) -> [String] {
        guard depth < 8, let alias = line.wholeMatch(of: /(\s*)([^\s#][^:#]*):\s+\*([\w.-]+)\s*/),
            let block = blocks[String(alias.3)]
        else { return [line] }
        let merge = alias.2 == "<<"
        let pad = String(alias.1) + (merge ? "" : "  ")
        let lines = block.flatMap { aliased(pad + $0, blocks, depth: depth + 1) }
        return merge ? lines : [String(alias.1) + alias.2 + ":"] + lines
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
}
