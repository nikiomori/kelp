// What an action's answer says beside the page: the element it reached and what it brought.
import Core
import Foundation

extension BrowserTab {
    /// Lines of the page an answer carries at most: the rest is a snapshot away.
    nonisolated static let shownLines = 40

    /// `answer` with the name of the element `ref` was in the snapshot it came from, and what the page shows since:
    /// another page's top (`page`: also for open, which a new tab answers as info), or the lines that came in this one
    /// (`new`), so the agent needn't take a snapshot to see what its action did.
    func looked(_ action: BrowserAction, ref: String?, _ answer: JSONValue) async throws -> JSONValue {
        guard case .object(var fields) = answer else { return answer }
        if let ref, let name = drive?.names[ref] { fields["element"] = .string(name) }
        let change = fields["change"]?.string
        let went = [.open, .reload, .back, .info].contains(action) || change == "new page"
        guard went || change == "page changed", fields["error"] == nil else { return .object(fields) }
        let lines = Array(try await snapshot("", max: 20000).components(separatedBy: "\n").dropFirst())
        if went {
            fields["page"] = .string(Self.top(lines))
        } else if let fresh = Self.fresh(lines) {
            fields["new"] = .string(fresh)
        }
        return .object(fields)
    }

    /// A snapshot (of what's inside `ref`, when given), its refs' names kept for the answers of actions on them.
    func snapshot(_ ref: String, max: Int) async throws -> String {
        let text = try await run(Self.snapshotJS, ["ref": ref, "max": max]) as? String ?? ""
        for line in text.split(separator: "\n") {
            if let (ref, name) = Self.named(String(line)) { drive?.names[ref] = name }
        }
        return text
    }

    /// `- button "Save" [checked] [ref=e12] [new]` → (`e12`, `button "Save"`): the role and name, without states.
    nonisolated static func named(_ line: String) -> (String, String)? {
        guard let at = line.range(of: " [ref=e"), let end = line[at.upperBound...].firstIndex(of: "]") else {
            return nil
        }
        let ref = "e" + line[at.upperBound..<end]
        var what = line[..<at.lowerBound].drop { $0 == " " || $0 == "-" }
        if let quote = what.lastIndex(of: "\"") {
            what = what[...quote]
        } else if let state = what.range(of: " [") {
            what = what[..<state.lowerBound]
        }
        return (ref, String(what))
    }

    /// A page's first lines, and how many more there are.
    nonisolated static func top(_ lines: [String]) -> String {
        guard lines.count > shownLines else { return lines.joined(separator: "\n") }
        return (lines.prefix(shownLines) + ["… \(lines.count - shownLines) more lines: snapshot shows them"])
            .joined(separator: "\n")
    }

    /// The lines marked `[new]`, each under the lines it sits in; nil when none came.
    nonisolated static func fresh(_ lines: [String]) -> String? {
        let all = [""] + lines   // `kept` passes over a first line: the page's own
        let keep = kept(all) { $0.hasSuffix(" [new]") }.map { all[$0] }
        guard !keep.isEmpty else { return nil }
        guard keep.count > shownLines else { return keep.joined(separator: "\n") }
        return (keep.prefix(shownLines) + ["… \(keep.count - shownLines) more: snapshot shows them"])
            .joined(separator: "\n")
    }
}
