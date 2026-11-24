import Core
import Foundation

/// A change by hand with All like this on (`CanvasLayers`): it goes to every element of the chosen one's class, on
/// every board that has one, as one hand edit a board, named by the class.
extension MarkdownTab {
    func restyleAll(_ body: [String: Any]) {
        guard let like = body["like"] as? [String: Any], let cls = like["cls"] as? String,
            let boards = like["boards"] as? [String]
        else { return }
        let many = body["props"] as? [String: Any]
        let props: [(String, String?)] =
            many.map { all in all.keys.sorted().map { ($0, all[$0] as? String) } }
            ?? [(body["property"] as? String ?? "", body["value"] as? String)]
        let what = props.map(\.0).joined(separator: ", "), to = props.map { $0.1 ?? "none" }.joined(separator: ", ")
        for board in boards {
            let edit = { (_: String) in HandEdit(board: board, id: "." + cls, what: what, from: nil, to: to) }
            rewrite(board, edit: edit) { source in
                props.reduce(Optional(source)) { text, p in
                    text.flatMap { BoardEdit.setStyle($0, className: cls, property: p.0, value: p.1)?.0 }
                }
            }
        }
    }
}

extension MarkdownTab {
    /// The words of Edit's Link, Picture and Arrange sections (`CanvasEditMore`).
    var canvasEditMoreLabels: [String: String] {
        [
            "link": String(localized: "Link"), "address": String(localized: "Address"),
            "no": String(localized: "No"), "yes": String(localized: "Yes"),
            "here": String(localized: "Opens in the same window"),
            "newWindow": String(localized: "New Window"), "picture": String(localized: "Picture"),
            "alt": String(localized: "Description"), "words": String(localized: "VoiceOver reads its description"),
            "decoration": String(localized: "Decoration"),
            "decorationTip": String(localized: "Decoration: VoiceOver skips it"),
            "arrange": String(localized: "Arrange"), "direction": String(localized: "Direction"),
            "across": String(localized: "Across"), "down": String(localized: "Down"),
            "distribute": String(localized: "Distribute"), "alignItems": String(localized: "Align"),
            "start": String(localized: "Start"), "middle": String(localized: "Middle"),
            "end": String(localized: "End"), "between": String(localized: "Space Between"),
            "stretch": String(localized: "Stretch")
        ]
    }

    /// A link's address or window, or a picture's words, changed in Edit's column (`CanvasEditMore`).
    func attributeMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard kind == "attribute" else { return false }
        guard let board = body["board"] as? String, let id = body["id"] as? String,
            let name = body["name"] as? String, ["href", "target", "alt"].contains(name)
        else { return true }
        let value = body["value"] as? String
        let edit = { (source: String) in
            HandEdit(board: board, id: id, what: name, from: BoardEdit.attribute(source, id: id, name: name), to: value)
        }
        rewrite(board, edit: edit) { BoardEdit.setAttribute($0, id: id, name: name, value: value) }
        return true
    }
}
