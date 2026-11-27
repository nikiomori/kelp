import Foundation

/// A motion page's entrances, exits and scene transitions chosen by hand: each kept on its element as
/// `data-kelp-in` / `data-kelp-out` ("rise 0.8 ease-out 1.2": what, seconds, easing, start), from which Kelp writes
/// one `<style id="kelp-motion">`: the keyframes used and a rule per element. Letters and words come in one after
/// another: the text is cut into spans with `--i`, and the rule is on them. They are ordinary CSS animations, so the
/// timeline shows them and their keyframes can be changed like any.
public enum MotionPresets {
    public enum Which: String, Sendable { case entrance = "in", exit = "out" }

    /// What each preset is, as keyframes.
    static let keyframes: [String: String] = [
        "fade": "from { opacity: 0 }", "rise": "from { opacity: 0; translate: 0 40px }",
        "pop": "0% { opacity: 0; scale: .6 } 70% { opacity: 1; scale: 1.05 } 100% { scale: 1 }",
        "fade-out": "to { opacity: 0 }", "rise-out": "to { opacity: 0; translate: 0 -40px }",
        "slide": "from { translate: 100% 0 }", "slide-out": "to { translate: -100% 0 }",
        "wipe": "from { clip-path: inset(0 100% 0 0) }", "zoom": "from { opacity: 0; scale: 1.15 }",
        "zoom-out": "to { opacity: 0; scale: .9 }"
    ]
    /// Entrances by name; letters and words are a rise of each in turn.
    public static let entrances = ["fade", "rise", "pop", "letters", "words"]
    public static let exits = ["fade-out", "rise-out"]

    /// `page` with element `id`'s entrance or exit set to `preset` (nil takes it away), lasting `length` seconds from
    /// `start`, eased by `easing`. Letters and words cut its text into spans (nil when it holds more than text).
    /// What is chosen: the preset (nil: none), its seconds, its easing, and when it starts.
    public struct Choice: Sendable {
        public var preset: String?, length: Double, easing: String, start: Double
        public init(_ preset: String?, length: Double, easing: String, start: Double) {
            self.preset = preset
            self.length = length
            self.easing = easing
            self.start = start
        }
    }

    public static func set(_ page: String, id: String, _ which: Which, _ choice: Choice) -> String? {
        let (preset, length, easing, start) = (choice.preset, choice.length, choice.easing, choice.start)
        let value = preset.map {
            "\($0) \(number(length)) \(easing.replacingOccurrences(of: " ", with: "")) \(number(start))"
        }
        guard var out = BoardEdit.setAttribute(page, id: id, name: "data-kelp-\(which.rawValue)", value: value) else {
            return nil
        }
        if which == .entrance, let preset, preset == "letters" || preset == "words" {
            guard let split = cut(out, id: id, words: preset == "words") else { return nil }
            out = split
        }
        return refresh(out)
    }

    /// The page's `<style id="kelp-motion">` written again from its elements' `data-kelp-in` and `data-kelp-out`.
    public static func refresh(_ page: String) -> String {
        var used = Set<String>(), rules: [String] = []
        for tag in page.matches(of: /<[a-zA-Z][^<>]*\sdata-id="([^"]+)"[^<>]*>/) {
            let text = String(tag.output.0), id = String(tag.output.1)
            let entrance = attribute(text, "data-kelp-in").map(parse),
                exit = attribute(text, "data-kelp-out").map(parse)
            guard entrance != nil || exit != nil else { continue }
            var own: [String] = []
            if let entering = entrance {
                if entering.name == "letters" || entering.name == "words" {
                    used.insert("rise")
                    let step = entering.name == "letters" ? 0.035 : 0.12
                    rules.append(
                        "[data-id='\(id)'] > span { display: inline-block; animation: kelp-rise \(entering.length)s "
                            + "\(entering.easing) calc(\(entering.start)s + var(--i) * \(number(step))s) both; }")
                } else {
                    used.insert(entering.name)
                    own.append("kelp-\(entering.name) \(entering.length)s \(entering.easing) \(entering.start)s both")
                }
            }
            if let leaving = exit {
                used.insert(leaving.name)
                own.append("kelp-\(leaving.name) \(leaving.length)s \(leaving.easing) \(leaving.start)s both")
            }
            if !own.isEmpty { rules.append("[data-id='\(id)'] { animation: \(own.joined(separator: ", ")); }") }
        }
        let frames = used.sorted().compactMap { name in keyframes[name].map { "@keyframes kelp-\(name) { \($0) }" } }
        let block =
            frames.isEmpty && rules.isEmpty
            ? "" : "<style id=\"kelp-motion\">\n" + (frames + rules).joined(separator: "\n") + "\n</style>"
        var out = page
        if let old = out.firstMatch(of: /<style id="kelp-motion">[\s\S]*?<\/style>\n?/) {
            out.replaceSubrange(old.range, with: block.isEmpty ? "" : block + "\n")
        } else if !block.isEmpty {
            let end =
                out.range(of: "</head>", options: .caseInsensitive)?.lowerBound
                ?? out.range(of: "<body", options: .caseInsensitive)?.lowerBound ?? out.startIndex
            out.insert(contentsOf: block + "\n", at: end)
        }
        return out
    }

    /// Element `id`'s own text cut into spans, a letter or a word each, numbered `--i`.
    static func cut(_ page: String, id: String, words: Bool) -> String? {
        guard let element = BoardEdit.element(page, id: id),
            let open = element.firstIndex(of: ">"), let close = element.range(of: "</", options: .backwards)
        else { return nil }
        let inner = String(element[element.index(after: open)..<close.lowerBound])
        let text: String
        if inner.contains("<") {
            // Cut before, its spans hold the text already; anything else in it isn't only text.
            guard inner.contains("--i") else { return nil }
            text = BoardEdit.unescape(inner.replacing(/<[^>]*>/, with: ""))
        } else {
            text = BoardEdit.unescape(inner)
        }
        let parts =
            words ? text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) : text.map(String.init)
        var index = 0
        let html = parts.map { part -> String in
            if part == " " { return " " }
            defer { index += 1 }
            return "<span style=\"--i: \(index)\">\(BoardEdit.escape(part))</span>"
        }.joined(separator: words ? " " : "")
        return BoardEdit.setInner(page, id: id, html: html)
    }

    /// `page` with element `id`'s entrance and exit starting `shift` seconds later (sooner when below 0), as its track
    /// dragged on the timeline: letters and words keep their spans, and their rule is written again.
    public static func shift(_ page: String, id: String, by shift: Double) -> String? {
        var out = page, any = false
        for which in [Which.entrance, .exit] {
            guard let value = BoardEdit.attribute(out, id: id, name: "data-kelp-\(which.rawValue)") else { continue }
            let parsed = parse(value), start = max((Double(parsed.start) ?? 0) + shift, 0)
            guard
                let set = BoardEdit.setAttribute(
                    out, id: id, name: "data-kelp-\(which.rawValue)",
                    value: "\(parsed.name) \(parsed.length) \(parsed.easing) \(number(start))")
            else { return nil }
            (out, any) = (set, true)
        }
        return any ? refresh(out) : nil
    }

    /// What an attribute value says: preset, seconds, easing, start.
    public static func parse(_ value: String) -> (name: String, length: String, easing: String, start: String) {
        let parts = value.split(separator: " ").map(String.init)
        return (
            parts.first ?? "fade", parts.count > 1 ? parts[1] : "0.6", parts.count > 2 ? parts[2] : "ease-out",
            parts.count > 3 ? parts[3] : "0"
        )
    }

    private static func attribute(_ tag: String, _ name: String) -> String? {
        guard let at = tag.range(of: " \(name)=\""), let end = tag[at.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(tag[at.upperBound..<end])
    }

    static func number(_ value: Double) -> String { String(format: "%g", (value * 1000).rounded() / 1000) }
}
