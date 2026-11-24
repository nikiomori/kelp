import Foundation

/// A motion page's stage changed shape (16:9 → 9:16): what was drawn for the old one is put, once, in a frame of its
/// design size (`data-kelp-frame="1920x1080"`) that is scaled to fit inside the new stage (bars at the sides), to fill
/// it (cropped at the centre), or left as it is. A later change scales the same frame again, from its design size.
public enum StageReframe: String, CaseIterable, Sendable {
    case fit, fill, none

    /// `source` with its stage's content framed for a stage of `width`×`height`, drawn for `old` when not yet framed.
    public func apply(_ source: String, old: (Int, Int), width: Int, height: Int) -> String {
        guard self != .none, let body = BoardEdit.bodyTag(source),
            let close = source.range(of: "</body>", options: [.caseInsensitive, .backwards])
        else { return source }
        let marker = #"data-kelp-frame=""#
        var design = old
        var inner = String(source[body.upperBound..<close.lowerBound])
        // Already framed: its design size, and what it holds.
        if let at = inner.range(of: marker),
            let size = inner[at.upperBound...].split(separator: "\"", maxSplits: 1).first,
            let end = inner[at.upperBound...].firstIndex(of: ">"),
            let last = inner.range(of: "</div>", options: .backwards)
        {
            let parts = size.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { design = (parts[0], parts[1]) }
            inner = String(inner[inner.index(after: end)..<last.lowerBound])
        }
        let (w, h) = (Double(design.0), Double(design.1))
        let k = self == .fit ? min(Double(width) / w, Double(height) / h) : max(Double(width) / w, Double(height) / h)
        let left = (Double(width) - w * k) / 2, top = (Double(height) - h * k) / 2
        let style =
            "position: absolute; left: \(Self.px(left)); top: \(Self.px(top)); width: \(design.0)px; "
            + "height: \(design.1)px; transform: scale(\(Self.number(k))); transform-origin: 0 0"
        let framed = "\n<div \(marker)\(design.0)x\(design.1)\" style=\"\(style)\">" + inner + "</div>\n"
        var out = source
        out.replaceSubrange(body.upperBound..<close.lowerBound, with: framed)
        return out
    }

    private static func number(_ v: Double) -> String { String(format: "%g", (v * 10000).rounded() / 10000) }
    private static func px(_ v: Double) -> String { number((v * 100).rounded() / 100) + "px" }
}
