// The fields that the answer to an agent's browser action adds to the page's address and title: the element the
// action reached, and what the page shows after it.
import Core
import Foundation

extension BrowserTab {
    /// The most lines of the page that one answer carries. The agent reads the rest with a snapshot.
    nonisolated static let shownLines = 40

    /// Returns `answer` with two additions, so the agent needn't take a snapshot to see what its action did. `element`
    /// is the name `ref` had in the snapshot the ref came from. Then `page` holds the top of the page when the action
    /// led to another page (also for open, which a new tab answers as info), or `new` holds the lines that came in this
    /// page.
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

    /// Returns a snapshot of the page, or of what's inside `ref` when given. It keeps the name of each ref in it, so
    /// the answer to a later action on that ref can name the element.
    func snapshot(_ ref: String, max: Int) async throws -> String {
        let text = try await run(Self.snapshotJS, ["ref": ref, "max": max]) as? String ?? ""
        for line in text.split(separator: "\n") {
            if let (ref, name) = Self.named(String(line)) { drive?.names[ref] = name }
        }
        return text
    }

    /// Returns the ref of a snapshot line and the element's role and name, without its states. For example,
    /// `- button "Save" [checked] [ref=e12] [new]` gives (`e12`, `button "Save"`).
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

    /// Returns the first lines of a page, and a note of how many more there are.
    nonisolated static func top(_ lines: [String]) -> String {
        guard lines.count > shownLines else { return lines.joined(separator: "\n") }
        return (lines.prefix(shownLines) + ["… \(lines.count - shownLines) more lines: snapshot shows them"])
            .joined(separator: "\n")
    }

    /// Returns the lines marked `[new]`, each under the lines that contain it, or nil when no new line came.
    nonisolated static func fresh(_ lines: [String]) -> String? {
        let all = [""] + lines   // `kept` skips the first line (the page's own), so a blank one stands in
        let keep = kept(all) { $0.hasSuffix(" [new]") }.map { all[$0] }
        guard !keep.isEmpty else { return nil }
        guard keep.count > shownLines else { return keep.joined(separator: "\n") }
        return (keep.prefix(shownLines) + ["… \(keep.count - shownLines) more: snapshot shows them"])
            .joined(separator: "\n")
    }
}
