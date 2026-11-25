import Foundation

/// Ready parts for a motion page, put in at the playhead by hand (Edit's element menu › Insert Block): a name plate, a
/// title card, a quote, a figure, a section title, a progress bar, a call to action and an end card. Each is plain
/// HTML in the page's own fonts and accent (`var(--accent)`), with an entrance and an exit (`MotionPresets`), so the
/// timeline shows it as a clip and the inspector changes it as any element.
public enum MotionBlocks {
    public static let names = ["name", "title", "quote", "figure", "section", "progress", "action", "end"]

    /// `page` with block `name` added as element `id`, shown over `time` (seconds) on a `stage` (w, h).
    public static func add(_ page: String, _ name: String, id: String, time: ClosedRange<Double>, stage: (Int, Int))
        -> String?
    {
        guard
            let html = html(
                name, id: id, start: time.lowerBound, length: time.upperBound - time.lowerBound, stage: stage)
        else { return nil }
        return MotionPresets.refresh(BoardEdit.appendToBody(page, html))
    }

    static func html(_ name: String, id: String, start: Double, length: Double, stage: (Int, Int)) -> String? {
        let (w, h) = (Double(stage.0), Double(stage.1)), u = min(w, h) / 1080   // sizes for a 1080 stage, scaled
        let px = { (v: Double) in "\(Int((v * u).rounded()))px" }
        let font = "font-family: var(--font-body, -apple-system, sans-serif)"
        let n = MotionPresets.number
        let into = { (preset: String) in "\(preset) 0.6 ease-out \(n(start))" }
        let away = "fade-out 0.4 ease-in \(n(max(start, start + length - 0.4)))"
        let times = "data-start=\"\(n(start))\" data-duration=\"\(n(length))\""
        let own = { (title: String, style: String, enter: String) in
            "data-id=\"\(id)\" data-title=\"\(title)\" \(times) data-kelp-in=\"\(into(enter))\" "
                + "data-kelp-out=\"\(away)\" style=\"position: absolute; \(font); \(style)\""
        }
        let accent = "var(--accent, #0a84ff)", ink = "color: var(--text, #fff)"
        switch name {
        case "name":
            let box =
                "left: \(px(96)); bottom: \(px(120)); padding: \(px(18)) \(px(28)); background: rgba(0,0,0,.72); "
                + "border-left: \(px(8)) solid \(accent); color: #fff"
            return "<div \(own("Name Plate", box, "slide"))>"
                + "<div style=\"font-size: \(px(44)); font-weight: 700\">Name Surname</div>"
                + "<div style=\"font-size: \(px(28)); opacity: .8\">Role, Company</div></div>"
        case "title":
            let box = "inset: 0; display: grid; place-content: center; text-align: center; \(ink)"
            return "<div \(own("Title Card", box, "rise"))>"
                + "<div style=\"font-size: \(px(120)); font-weight: 800; letter-spacing: -0.02em\">The Title</div>"
                + "<div style=\"font-size: \(px(44)); opacity: .7\">A line under it</div></div>"
        case "quote":
            return "<figure \(own("Quote", "left: 12%; right: 12%; top: 30%; margin: 0; \(ink)", "fade"))>"
                + "<blockquote style=\"margin: 0; font-size: \(px(64)); font-weight: 600; line-height: 1.2\">"
                + "“The words someone said.”</blockquote>"
                + "<figcaption style=\"margin-top: \(px(24)); font-size: \(px(32)); opacity: .7\">— Who said it"
                + "</figcaption></figure>"
        case "figure":
            let box = "left: 50%; top: 50%; translate: -50% -50%; text-align: center; \(ink)"
            return "<div \(own("Big Number", box, "pop"))>"
                + "<div style=\"font-size: \(px(200)); font-weight: 800; color: \(accent); line-height: 1\">42%</div>"
                + "<div style=\"font-size: \(px(40)); opacity: .8\">what the number is</div></div>"
        case "section":
            return "<div \(own("Section Title", "left: \(px(120)); top: 40%; \(ink)", "slide"))>"
                + "<div style=\"font-size: \(px(36)); color: \(accent); font-weight: 700\">01</div>"
                + "<div style=\"font-size: \(px(96)); font-weight: 800\">Section</div></div>"
        case "progress":
            let box = "left: 0; right: 0; bottom: 0; height: \(px(10)); background: rgba(255,255,255,.15)"
            return "<div \(own("Progress Bar", box, "fade"))>"
                + "<div data-id=\"\(id)-fill\" data-kelp-in=\"wipe \(n(length)) linear \(n(start))\" "
                + "style=\"height: 100%; background: \(accent)\"></div></div>"
        case "action":
            let box =
                "left: 50%; bottom: \(px(140)); translate: -50% 0; padding: \(px(22)) \(px(48)); border-radius: 999px; "
                + "background: \(accent); color: #fff; font-size: \(px(44)); font-weight: 700"
            return "<div \(own("Call to Action", box, "pop"))>Try it today</div>"
        case "end":
            let box =
                "inset: 0; display: grid; place-content: center; text-align: center; background: var(--bg, #000); \(ink)"
            return "<div \(own("End Card", box, "fade"))>"
                + "<div style=\"font-size: \(px(110)); font-weight: 800\">Thanks</div>"
                + "<div style=\"font-size: \(px(40)); opacity: .7\">example.com</div></div>"
        default: return nil
        }
    }
}
