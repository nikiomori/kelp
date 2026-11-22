import AppKit
import DesignKit
import ImageIO
import UniformTypeIdentifiers

/// How a motion page is exported: as an MP4 or a looping GIF, at 24, 30 or 60 frames a second, at the stage's size or
/// twice it (4K for a 1080p stage). A GIF plays at 30 at most.
struct MotionExport: Equatable {
    enum Format: String, CaseIterable { case mp4, gif }
    var format = Format.mp4, fps = 30.0, scale = 1.0

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
        let rows = [
            (String(localized: "Format"), format), (String(localized: "Frame Rate"), rate),
            (String(localized: "Size"), size)
        ].map { name, control in
            NSStackView(views: [NSTextField.label(name, font: .ui(TextSize.row), color: .secondaryLabelColor), control])
        }
        let export = TextButton(String(localized: "Export…")) { [weak self] in
            guard let self else { return }
            popover.performClose(nil)
            go(options)
        }
        let stack = NSStackView(views: rows + [export])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    @objc private func changed() {
        options.format = MotionExport.Format.allCases[max(format.selectedSegment, 0)]
        options.fps = MotionExport.rates[max(rate.selectedSegment, 0)]
        options.scale = size.selectedSegment == 1 ? 2 : 1
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
