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
    func looked(_ action: BrowserAction, element: String?, _ answer: JSONValue) async throws -> JSONValue {
        guard case .object(var fields) = answer else { return answer }
        if let element { fields["element"] = .string(element) }
        let change = fields["change"]?.string
        let went = [.open, .reload, .back, .info].contains(action) || change == "new page"
        guard went || change == "page changed", fields["error"] == nil else { return .object(fields) }
        if let body = try await snapshot("", max: 20000, went ? .page : .fresh) {
            fields[went ? "page" : "new"] = .string(body)
        }
        return .object(fields)
    }

    /// Returns a snapshot of the page, or of what's inside `ref` when given. It keeps the name of each ref in it, so
    /// the answer to a later action on that ref can name the element.
    func snapshot(_ ref: String, max: Int, _ format: SnapshotFormat) async throws -> String? {
        let drive = self.drive, document = drive?.nameDocument
        drive?.snapshotNumber += 1
        let number = drive?.snapshotNumber ?? 0
        let text = try await run(Self.snapshotJS, ["ref": ref, "max": max]) as? String ?? ""
        let (reply, names) = await Self.snapshotReply(text, format)
        if let drive, drive === self.drive, drive.nameDocument == document {
            // A newer, scoped snapshot may have finished first. Keep its names, but don't lose disjoint refs.
            for (ref, name) in names where (drive.names[ref]?.number ?? 0) <= number {
                drive.names[ref] = (number, name)
            }
        }
        return reply
    }

    enum SnapshotFormat: Sendable {
        case find(String), page, fresh
    }

    /// Pure CPU work on the generic executor. WebKit and the document's mutable ref cache stay on the main actor.
    nonisolated static func snapshotReply(_ text: String, _ format: SnapshotFormat) async
        -> (String?, [(String, String)])
    {
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).lazy.map { Substring($0) }
        let names: [(String, String)] = lines.compactMap(named)
        let body = lines.dropFirst()
        switch format {
        case .find(let query) where query.isEmpty:
            return (text, names)
        case .find(let query):
            let keep = kept(body, children: 20) { $0.localizedCaseInsensitiveContains(query) }
            var reply = String(lines.first ?? "")
            if !keep.contains(true) {
                reply += "\nNothing on the page mentions \"\(query)\"."
            } else {
                for (line, kept) in zip(body, keep) where kept {
                    reply += "\n"
                    reply.append(contentsOf: line)
                }
            }
            return (reply, names)
        case .page:
            var reply = body.prefix(shownLines).joined(separator: "\n")
            if body.count > shownLines { reply += "\n… \(body.count - shownLines) more lines: snapshot shows them" }
            return (reply, names)
        case .fresh:
            let keep = kept(body) { $0.hasSuffix(" [new]") }
            var reply = "", count = 0
            for (line, kept) in zip(body, keep) where kept {
                if count < shownLines {
                    if count > 0 { reply += "\n" }
                    reply.append(contentsOf: line)
                }
                count += 1
            }
            if count > shownLines { reply += "\n… \(count - shownLines) more: snapshot shows them" }
            return (count == 0 ? nil : reply, names)
        }
    }

    /// Scan upwards once. The deepest outstanding match seeks a parent strictly shallower than itself. Any such
    /// line is kept and becomes the new depth to beat: all shallower outstanding matches still seek its ancestors.
    private nonisolated static func kept<Lines: RandomAccessCollection>(
        _ body: Lines, children: Int = 0, matching: (Substring) -> Bool
    ) -> [Bool] where Lines.Index == Int, Lines.Element == Substring {
        var keep = [Bool](repeating: false, count: body.count), seeking = 0
        for i in body.indices.reversed() {
            let line = body[i], depth = line.utf8.prefix { $0 == 32 }.count
            let match = matching(line)
            if match || depth < seeking {
                keep[i - body.startIndex] = true
                seeking = depth
            }
            if match && children > 0 {
                // Cap the window before inspecting indentation, even in a deeply nested tree.
                for j in (i + 1)..<min(body.endIndex, i + 1 + children) {
                    guard body[j].utf8.prefix(while: { $0 == 32 }).count > depth else { break }
                    keep[j - body.startIndex] = true
                }
            }
        }
        return keep
    }

    /// Returns the ref of a snapshot line and the element's role and name, without its states. For example,
    /// `- button "Save" [checked] [ref=e12] [new]` gives (`e12`, `button "Save"`).
    nonisolated static func named(_ line: Substring) -> (String, String)? {
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
}
