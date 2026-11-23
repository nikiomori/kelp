import AppKit
import DesignKit
import ImageIO
import UniformTypeIdentifiers

/// How a motion page is exported: as an MP4 or a looping GIF, at 24, 30 or 60 frames a second, at the stage's size or
/// twice it (4K for a 1080p stage). A GIF plays at 30 at most.
struct MotionExport: Equatable {
    enum Format: String, CaseIterable { case mp4, gif }
    var format = Format.mp4, fps = 30.0, scale = 1.0
    /// The work area, when one is set, and whether the video is only that.
    var range: ClosedRange<Double>?, onlyRange = false

    var type: UTType { format == .gif ? .gif : .mpeg4Movie }
    /// The frames a second the file is made at.
    var rate: Double { format == .gif ? min(fps, 30) : fps }
    static let rates: [Double] = [24, 30, 60]
}

/// The popover under Export Video: the format, the frame rate and the size, each a row of segments, and Export….
@MainActor
final class MotionExportPopover: NSObject {
    private let popover = NSPopover()
    private var options: MotionExport
    private let stage: (width: Int, height: Int)
    private let format = CapsuleSegments(labels: ["MP4", "GIF"])
    private let rate = CapsuleSegments(labels: MotionExport.rates.map { "\(Int($0))" })
    private let size: CapsuleSegments
    private let onlyRange = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let go: (MotionExport) -> Void

    init(_ options: MotionExport, stage: (width: Int, height: Int), go: @escaping (MotionExport) -> Void) {
        self.options = options
        self.stage = stage
        self.go = go
        size = CapsuleSegments(
            labels: [1, 2].map { "\(stage.width * $0) × \(stage.height * $0)" })
        super.init()
    }

    func show(below view: NSView) {
        format.selectedSegment = MotionExport.Format.allCases.firstIndex(of: options.format) ?? 0
        rate.selectedSegment = MotionExport.rates.firstIndex(of: options.fps) ?? 1
        size.selectedSegment = options.scale == 2 ? 1 : 0
        for control in [format, rate, size] {
            control.target = self
            control.action = #selector(changed)
        }
        // As the system's popovers have it: each part's name over its choices, and one main button.
        var parts: [NSView] = []
        for (name, control) in [
            (String(localized: "Format"), format), (String(localized: "Frame Rate"), rate),
            (String(localized: "Size"), size)
        ] {
            control.controlSize = .small
            let label = NSTextField.label(
                name, font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
            parts.append(label)
            parts.append(control)
        }
        let export = NSButton(title: String(localized: "Export…"), target: self, action: #selector(go(_:)))
        export.keyEquivalent = "\r"
        export.controlSize = .regular
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let foot = NSStackView(views: [spacer, export])   // the main button at the trailing edge
        if let range = options.range {
            onlyRange.title = String(
                format: String(localized: "Only the Work Area (%.1f–%.1f s)"), range.lowerBound, range.upperBound)
            onlyRange.state = options.onlyRange ? .on : .off
            onlyRange.target = self
            onlyRange.action = #selector(changed)
            parts += [onlyRange]
        }
        let stack = NSStackView(views: parts + [foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        for (i, view) in parts.enumerated() where i % 2 == 0 && i < 6 {
            stack.setCustomSpacing(Metrics.gapTight, after: view)
        }
        stack.setCustomSpacing(Metrics.inset, after: parts.last ?? size)
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        foot.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// The popover's width, as the system's are.
    static let width: CGFloat = 300

    @objc private func go(_ sender: Any?) {
        popover.performClose(nil)
        go(options)
    }

    @objc private func changed() {
        options.format = MotionExport.Format.allCases[max(format.selectedSegment, 0)]
        options.fps = MotionExport.rates[max(rate.selectedSegment, 0)]
        options.scale = size.selectedSegment == 1 ? 2 : 1
        options.onlyRange = onlyRange.state == .on
    }
}

/// Writes frames given one at a time as a GIF that loops, each shown for one frame of `fps`.
final class MotionGIF {
    private let file: CGImageDestination
    private let delay: Double

    init(_ url: URL, frames: Int, fps: Double) throws {
        guard let made = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        file = made
        delay = 1 / fps
        let loops = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(file, loops as CFDictionary)
    }

    func add(_ image: CGImage) {
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        CGImageDestinationAddImage(file, image, frame as CFDictionary)
    }

    func finish() throws {
        guard CGImageDestinationFinalize(file) else { throw CocoaError(.fileWriteUnknown) }
    }
}
