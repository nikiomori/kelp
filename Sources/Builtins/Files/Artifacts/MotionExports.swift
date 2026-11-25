import AppKit
import CoreGraphics
import DesignKit
import Observation

/// The videos made from a motion page, newest first, under Export Video's options: each one's file, how far it got
/// (with Cancel), Show in Finder once made, or why it failed.
@MainActor
enum MotionExports {
    @Observable
    final class Item {
        let url: URL
        /// 0–1 while it's made; nil once it's done.
        var progress: Double? = 0
        var failure: String?
        /// Its check once made (`MotionVerify`).
        var verdict: MotionVerify?
        @ObservationIgnored var task: Task<Void, Never>?
        init(_ url: URL) { self.url = url }
    }

    /// The list's views: a title and a row for each.
    static func list(_ items: [Item]) -> [NSView] {
        guard !items.isEmpty else { return [] }
        let title = NSTextField.label(
            String(localized: "Recent"), font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        return [title] + items.prefix(5).map(row)
    }

    private static func row(_ item: Item) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.radiusXS
        let name = NSTextField.label(item.url.lastPathComponent, font: .ui(TextSize.row))
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let how = NSTextField.label("", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor)
        let act = TextButton("")
        let row = NSStackView(views: [dot, name, NSView(), how, act])
        row.spacing = Metrics.gap
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)
        ])
        track(owner: row) {
            Values(item.progress, item.failure, item.verdict)
        } changed: { _ in
            let progress = item.progress, failure = item.failure, verdict = item.verdict
            let made: NSColor = verdict.map { $0.ok ? .systemGreen : .systemOrange } ?? .tertiaryLabelColor
            dot.layer?.backgroundColor =
                (failure != nil ? NSColor.systemRed : progress != nil ? .controlAccentColor : made).cgColor
            // A failure was told in a banner when it happened; its row keeps why, in a word and in full on hover.
            how.stringValue =
                failure.map { _ in String(localized: "Failed") } ?? progress.map { "\(Int($0 * 100)) %" }
                ?? verdict?.summary ?? ""
            how.toolTip = failure ?? verdict.map { ($0.problems + $0.warnings).joined(separator: "\n") }
            how.isHidden = how.stringValue.isEmpty
            act.isHidden = failure != nil
            if progress != nil {
                act.title = String(localized: "Cancel")
                act.onClick = { item.task?.cancel() }
            } else {
                act.title = String(localized: "Show")
                act.onClick = { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
        }
        return row
    }

    /// A frame with a transparent background, from two pictures of it: on black and on white. Over black a pixel is
    /// its colour times its opacity (premultiplied), and white shows through by what it lets pass.
    nonisolated static func matte(black: CGImage, white: CGImage, width: Int, height: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        func pixels(_ image: CGImage) -> CGContext? {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: info)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context
        }
        guard let b = pixels(black), let w = pixels(white), let bd = b.data, let wd = w.data else { return nil }
        let on = bd.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let off = wd.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let through =
                (Int(off[i]) - Int(on[i]) + Int(off[i + 1]) - Int(on[i + 1]) + Int(off[i + 2]) - Int(on[i + 2])) / 3
            let alpha = max(0, min(255, 255 - through))
            on[i] = min(on[i], UInt8(alpha))
            on[i + 1] = min(on[i + 1], UInt8(alpha))
            on[i + 2] = min(on[i + 2], UInt8(alpha))
            on[i + 3] = UInt8(alpha)
        }
        return b.makeImage()
    }
}
