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
        let step = UUID()   // one ⌘Z takes it back on every board
        for board in boards {
            let edit = { (_: String) in HandEdit(board: board, id: "." + cls, what: what, from: nil, to: to) }
            rewrite(board, by: step, edit: edit) { source in
                props.reduce(Optional(source)) { text, p in
                    text.flatMap { BoardEdit.setStyle($0, className: cls, property: p.0, value: p.1)?.0 }
                }
            }
        }
    }
}
