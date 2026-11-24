import AppKit
import Core
import DesignKit

extension MarkdownTab {
    /// The words of Edit's Link, Picture, Arrange and Flow sections, Check's fixes and the boards' widths
    /// (`CanvasEditMore` and the scripts it brings).
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
            "stretch": String(localized: "Stretch"), "use": String(localized: "Use %@"),
            "allOf": String(localized: "All %d"), "describe": String(localized: "Describe"),
            "mark": String(localized: "Mark It"), "asDrawn": String(localized: "As Drawn"),
            "drag": String(localized: "Drag to see it at any width"), "flow": String(localized: "Flow"),
            "goesTo": String(localized: "Goes To"), "nowhere": String(localized: "Nowhere"),
            "toAgent": String(localized: "To the Agent"), "fromData": String(localized: "From Data"),
            "table": String(localized: "Table"), "chooseTable": String(localized: "Choose…"),
            "field": String(localized: "Column"), "row": String(localized: "Row"),

            "longer": String(localized: "+40%"), "rtl": String(localized: "RTL"),

            "needsScreen": String(localized: "Needs a screen after this: what happens when it's pressed?")
        ]
    }

    /// A link's address or window, or a picture's words, changed in Edit's column (`CanvasEditMore`).
    func attributeMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        if kind == "linkMenu" {
            linkMenu(body)
            return true
        }
        if kind == "objectAt" {
            objectMessage(body)
            return true
        }
        if kind == "chartData" {
            chartMessage(body)
            return true
        }
        if rowsMessage(kind, body) { return true }
        guard kind == "attribute" else { return false }
        guard let board = body["board"] as? String, let id = body["id"] as? String,
            let name = body["name"] as? String, ["href", "target", "alt", "data-link"].contains(name)
        else { return true }
        let value = body["value"] as? String
        let edit = { (source: String) in
            HandEdit(board: board, id: id, what: name, from: BoardEdit.attribute(source, id: id, name: name), to: value)
        }
        rewrite(board, edit: edit) { BoardEdit.setAttribute($0, id: id, name: name, value: value) }
        return true
    }

    /// Check's Use <token> or All N: each element on the board takes the token in place of the value.
    func tokenMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard kind == "useToken" else { return false }
        let properties = ["color", "background", "font-size", "border-radius"]
        guard let board = body["board"] as? String, let value = body["value"] as? String,
            value.wholeMatch(of: /var\(--[A-Za-z0-9_-]+\)/) != nil,
            let list = body["changes"] as? [[String: Any]]
        else { return true }
        let changes = list.compactMap { c -> (id: String, property: String)? in
            guard let id = c["id"] as? String, let p = c["property"] as? String, properties.contains(p) else {
                return nil
            }
            return (id, p)
        }
        guard let first = changes.first else { return true }
        let edit = { (source: String) in
            HandEdit(
                board: board, id: first.id, what: first.property + (changes.count > 1 ? " ×\(changes.count)" : ""),
                from: BoardEdit.style(source, id: first.id, property: first.property), to: value)
        }
        rewrite(board, edit: edit) { source in
            changes.reduce(Optional(source)) { text, c in
                text.flatMap { BoardEdit.setStyle($0, id: c.id, property: c.property, value: value) }
            }
        }
        return true
    }

    /// Goes To's menu: Nowhere and the design's other boards, the one the control goes to ticked.
    func linkMenu(_ body: [String: Any]) {
        guard let board = body["board"] as? String, let id = body["id"] as? String,
            let boards = body["boards"] as? [[String: Any]]
        else { return }
        let now = body["now"] as? String ?? "", menu = NSMenu()
        let pick = { [weak self] (name: String?) in
            self?.runJS("window.kelpLinkTo?.(\(Self.js(board)), \(Self.js(id)), \(name.map(Self.js) ?? "null"))")
        }
        menu.add(String(localized: "Nowhere")) { pick(nil) }.state = now.isEmpty ? .on : .off
        menu.addItem(.separator())
        for b in boards {
            guard let name = b["name"] as? String else { continue }
            menu.add(b["title"] as? String ?? name) { pick(name) }.state = name == now ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Mark on a picture: the outline of the object at the point clicked (0–1 across and down), worked out off the
    /// main thread, or none, and the page makes the mark.
    func objectMessage(_ body: [String: Any]) {
        let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue ?? 0.5 }
        guard let src = (body["src"] as? String).flatMap(URL.init(string:)), src.isFileURL else {
            return runJS("window.kelpObjectMark?.(null)")
        }
        let point = CGPoint(x: number("x"), y: number("y"))
        Task.detached {
            var points: [[Double]]?
            do {
                points = try ObjectOutline.outline(of: src, at: point)?.map { [Double($0.x), Double($0.y)] }
            } catch {
                points = nil   // a picture Vision can't read is marked whole
            }
            let answer = points.map { MarkdownTab.js($0) } ?? "null"
            await MainActor.run { self.runJS("window.kelpObjectMark?.(\(answer))") }
        }
    }
}
