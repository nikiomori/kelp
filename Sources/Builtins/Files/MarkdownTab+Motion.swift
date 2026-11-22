import AVFoundation
import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers
import WebKit
import WorkbenchKit

/// A motion page in its tab: the studio under it (`MotionStudio`) follows its time, and what the user moves, retimes
/// or retypes on the stage or the timeline is written into the page's file. Export Video records the page, a frame at
/// a time, as an MP4.
extension MarkdownTab {
    /// The frames a second of an exported video.
    static let videoFPS = 30.0

    func makeMotionStudio() -> MotionStudio {
        let made = MotionStudio { [weak self] call in self?.runJS(call) }
        made.onExport = { [weak self] in self?.exportVideo() }
        made.onClip = { [weak self] was, now, lane in
            lane == 0 ? self?.retime(scene: was, as: now) : self?.retime(was, as: now)
        }
        return made
    }

    /// The scripts a motion page is drawn with: Kelp's player at the frame rate chosen, back at the time it showed and
    /// with the element that was chosen.
    func motionScripts(at: Double) -> [String] {
        [
            MotionPage.source(fps: motionStudio.fps), "window.kelpMotion?.seek(\(at))",
            "window.kelpMotion?.choose(\(Self.js(motionStudio.chosen)))"
        ]
    }

    func motionMessage(_ body: [String: Any]) {
        let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue ?? 0 }
        let clips = { (key: String, start: String, length: String) in
            (body[key] as? [[String: Any]] ?? []).map { c in
                let begins = (c[start] as? NSNumber)?.doubleValue ?? 0
                let takes = (c[length] as? NSNumber)?.doubleValue ?? 0
                return MotionTimeline.Clip(
                    id: c["id"] as? String ?? "", title: c["title"] as? String ?? "", start: begins,
                    length: length == "end" ? takes - begins : takes,
                    delays: (c["delays"] as? [NSNumber])?.map(\.doubleValue) ?? [],
                    lengths: (c["lengths"] as? [NSNumber])?.map(\.doubleValue) ?? [])
            }
        }
        motionStudio.show(
            MotionStudio.State(
                at: number("t"), length: number("duration"), playing: body["playing"] as? Bool ?? false,
                width: Int(number("width")), height: Int(number("height")),
                scenes: clips("scenes", "start", "duration"), tracks: clips("tracks", "start", "end")))
    }

    /// Handles what the page says about its elements: one chosen, moved on the stage, or retyped.
    func motionEdit(_ kind: String, _ body: [String: Any]) {
        let id = body["id"] as? String ?? ""
        switch kind {
        case "motionChose": motionStudio.chose(id)
        case "motionMove":
            guard let value = body["translate"] as? String else { return }
            let was = BoardEdit.style(editor.text, id: id, property: "translate")
            rewritePage(HandEdit(board: pageFile, id: id, what: "translate", from: was, to: value)) {
                BoardEdit.setStyle($0, id: id, property: "translate", value: value)
            }
        case "motionText":
            guard let old = body["old"] as? String, let text = body["text"] as? String else { return }
            rewritePage(HandEdit(board: pageFile, id: id, what: "text", from: old, to: text)) {
                BoardEdit.setText($0, id: id, old: old, new: text)
            }
        default: break
        }
    }

    /// Moves or trims a scene: its `data-start` and `data-duration` become the block's start and length.
    func retime(scene was: MotionTimeline.Clip, as now: MotionTimeline.Clip) {
        let edit = HandEdit(
            board: pageFile, id: now.id, what: "data-start/data-duration",
            from: "\(Self.seconds(was.start))/\(Self.seconds(was.length))",
            to: "\(Self.seconds(now.start))/\(Self.seconds(now.length))")
        rewritePage(edit) { text in
            BoardEdit.setAttribute(text, id: now.id, name: "data-start", value: Self.seconds(now.start)).flatMap {
                BoardEdit.setAttribute($0, id: now.id, name: "data-duration", value: Self.seconds(now.length))
            }
        }
    }

    /// Moves an element's animations by as much as its block moved on the timeline, or, for one animation trimmed,
    /// gives it the block's start and length. They are set on the element itself (`animation-delay`,
    /// `animation-duration`), over what its CSS rule says.
    func retime(_ was: MotionTimeline.Clip, as now: MotionTimeline.Clip) {
        let shift = now.start - was.start
        let delays = was.delays.map { $0 + shift }
        let lengths = was.delays.count == 1 && now.length != was.length ? [now.length] : was.lengths
        let list = { (values: [Double]) in values.map { Self.seconds(max($0, 0)) + "s" }.joined(separator: ", ") }
        let edit = HandEdit(
            board: pageFile, id: now.id, what: "animation-delay/animation-duration",
            from: list(was.delays) + "/" + list(was.lengths), to: list(delays) + "/" + list(lengths))
        rewritePage(edit) { text in
            BoardEdit.setStyle(text, id: now.id, property: "animation-delay", value: list(delays)).flatMap {
                BoardEdit.setStyle($0, id: now.id, property: "animation-duration", value: list(lengths))
            }
        }
    }

    private static func seconds(_ value: Double) -> String { String(format: "%g", (value * 100).rounded() / 100) }

    /// The page's file name, as hand edits name it.
    private var pageFile: String { url.lastPathComponent }

    /// Changes the page's text with `change` and saves it, keeping `edit` for the agent and for ⌘Z. The page is drawn
    /// again at the time it showed. When the element isn't found for sure, nothing changes and the banner says why.
    private func rewritePage(_ edit: HandEdit, _ change: (String) -> String?) {
        let before = editor.text
        guard let text = change(before) else {
            return Banner.show(
                String(localized: "Couldn’t change “\(edit.id)” in the page as it is now: give it a data-id."),
                style: .error)
        }
        editor.apply(text: text, selection: NSRange(location: 0, length: 0))
        Task { _ = await saveFile?() }
        didHandEdit(edit, path: url.path, before: before, after: text)
    }

    /// Asks where to save the video, then records it.
    func exportVideo() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.deletingLastPathComponent().lastPathComponent + ".mp4"
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let to = panel.url else { return }
            Task { @MainActor in await self?.record(to: to) }
        }
    }

    /// Records the page from its first frame to its last into `to`, showing how far it got in the bar. The video
    /// opens in a tab when it's done.
    private func record(to: URL) async {
        do {
            guard
                let length = try await web.evaluateJavaScript("window.kelpMotion?.duration()", contentWorld: Self.world)
                    as? Double, length > 0,
                let stage = try await web.evaluateJavaScript("window.kelpMotion?.stage()", contentWorld: Self.world)
                    as? [Double], stage.count == 6
            else { throw RPCError.internalError("The page isn't a motion page.") }
            let frames = Int((length * Self.videoFPS).rounded(.up))
            let movie = try MotionMovie(to, width: Int(stage[4]), height: Int(stage[5]))
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: stage[0], y: stage[1], width: stage[2], height: stage[3])
            // The picture is the stage's own size in pixels, however small the pane shows it.
            config.snapshotWidth = NSNumber(value: stage[4] / Double(view.window?.backingScaleFactor ?? 2))
            for frame in 0...frames {
                motionStudio.exporting(frame, of: frames)
                let at = Double(frame) / Self.videoFPS
                _ = try await web.callAsyncJavaScript(
                    "return await window.kelpMotion.frameAt(at)", arguments: ["at": at], contentWorld: Self.world)
                let image = try await web.takeSnapshot(configuration: config)
                guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                try await movie.add(picture, at: at)
            }
            try await movie.finish(at: Double(frames + 1) / Self.videoFPS)
            motionStudio.exporting(nil, of: frames)
            app.workbench.open(TabURI.file(to.path))
        } catch {
            motionStudio.exporting(nil, of: 0)
            Banner.show(
                String(localized: "Couldn’t make the video: \(error.localizedDescription)"), style: .error)
        }
    }
}

/// Writes frames given one at a time, each at its own time, as an H.264 MP4. Unlike a recording, it waits for the
/// encoder rather than drop a frame.
private actor MotionMovie {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int

    init(_ url: URL, width: Int, height: Int) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}   // it writes only new
        // H.264 takes even sizes.
        self.width = max(2, width / 2 * 2)
        self.height = max(2, height / 2 * 2)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: self.width, AVVideoHeightKey: self.height
            ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: self.width, kCVPixelBufferHeightKey as String: self.height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func add(_ image: CGImage, at time: Double) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            await Task.yield()
        }
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
    }

    func finish(at time: Double) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
