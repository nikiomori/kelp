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
    func makeMotionStudio() -> MotionStudio {
        let made = MotionStudio { [weak self] call in self?.runJS(call) }
        made.onExport = { [weak self] options in self?.exportVideo(options) }
        made.onChoose = { [weak self] id in self?.chooseOnStage(id) }
        made.onRemove = { [weak self] id in self?.removeElement(MotionPage.board, id) }
        made.onHide = { [weak self] id, hide in self?.hideElement(id, hide) }
        made.onFormat = { [weak self] w, h in self?.resizeStage(w, h) }
        made.onGroup = { [weak self] moves in self?.retimeAll(moves) }
        made.onKeyframe = { [weak self] in self?.keyframe() }
        made.keyframes { k in
            k.onMove = { [weak self] id, from, to in self?.moveKeyframe(id, from: from, to: to) }
            k.menu = { [weak self] id, place in self?.keyframeMenu(id, place) }
        }
        made.onMany = { [weak self] kind, ids in
            kind == "remove" ? self?.removeElements(ids) : self?.copyClips(ids, cut: kind == "cut")
        }
        made.onCut = { [weak self] kind, id in
            switch kind {
            case "split": self?.splitClip(id)
            case "trimStart", "trimEnd": self?.trimClip(id, end: kind == "trimEnd")
            case "copy", "cut": self?.copyClip(id, cut: kind == "cut")
            default: self?.pasteClip()
            }
        }
        made.onDropFiles = { [weak self] files, at in
            Task { for file in files where Self.isMedia(file) { await self?.addMedia(file, at: nil, time: at) } }
        }
        made.onRestack = { [weak self] ids in self?.runJS("window.kelpMotion?.restack(\(Self.js(ids)))") }
        made.onDuplicate = { [weak self] id in self?.duplicateElement(MotionPage.board, id) }
        made.onClip = { [weak self] was, now, lane in
            // A scene, or a picture or video with its own time (no animations), moves by its data-start
            lane == 0 || now.delays.isEmpty ? self?.retime(scene: was, as: now) : self?.retime(was, as: now)
        }
        return made
    }

    /// The scripts a motion page is drawn with: Kelp's player at the frame rate chosen, back at the time it showed.
    func motionScripts(at: Double) -> [String] {
        [
            MotionPage.source(fps: motionStudio.fps), CanvasMotionKeys.source(labels: motionKeyLabels),
            "window.kelpMotion?.seek(\(at))"
        ]
    }

    /// Chooses element `id` on the stage, as a click in Edit does, turning Edit on.
    func chooseOnStage(_ id: String) {
        if !editing {
            setCanvasMode(.edit)
            onPageMode?(.edit)
        }
        chosen = (MotionPage.board, id)
        runJS("window.kelpSelect?.(\(Self.js(MotionPage.board)), \(Self.js(id)))")
    }

    /// The words of the column's Motion section and its curve.
    var motionKeyLabels: [String: String] {
        [
            "motion": String(localized: "Motion"), "keyframes": String(localized: "Keyframes"),
            "easing": String(localized: "Easing"), "curve": String(localized: "Curve"),
            "spring": String(localized: "Spring"), "wiggle": String(localized: "Wiggle"),
            "bounce": String(localized: "Bounce"), "count": String(localized: "Swings"),
            "presets": String(localized: "Ready Ones")
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
                    lengths: (c["lengths"] as? [NSNumber])?.map(\.doubleValue) ?? [],
                    hidden: c["hidden"] as? Bool ?? false,
                    keys: (c["keys"] as? [String: Any]).flatMap { k in
                        guard let name = k["name"] as? String else { return nil }
                        return MotionTimeline.Keys(
                            name: name, delay: (k["delay"] as? NSNumber)?.doubleValue ?? 0,
                            duration: (k["duration"] as? NSNumber)?.doubleValue ?? 0,
                            at: (k["at"] as? [NSNumber])?.map(\.doubleValue) ?? [],
                            easing: k["easing"] as? [String] ?? [])
                    })
            }
        }
        motionStudio.show(
            MotionStudio.State(
                at: number("t"), length: number("duration"), playing: body["playing"] as? Bool ?? false,
                width: Int(number("width")), height: Int(number("height")),
                scenes: clips("scenes", "start", "duration"), tracks: clips("tracks", "start", "end"),
                marks: (body["marks"] as? [[String: Any]] ?? []).compactMap { m in
                    guard let id = (m["id"] as? NSNumber)?.intValue, let time = (m["time"] as? NSNumber)?.doubleValue
                    else { return nil }
                    return MotionTimeline.Mark(
                        id: id, time: time, yours: ["draft", "check"].contains(m["state"] as? String ?? ""))
                },
                range: (body["range"] as? [NSNumber]).flatMap { r in
                    r.count == 2 && r[1].doubleValue > r[0].doubleValue ? r[0].doubleValue...r[1].doubleValue : nil
                }))
    }

    /// Gives the stage another shape: the body's `data-width` and `data-height`. The page's own layout is the
    /// user's or the agent's to fit to it.
    func resizeStage(_ width: Int, _ height: Int) {
        let (w, h) = MotionPage.size(editor.text)
        let edit = HandEdit(board: pageFile, id: "body", what: "size", from: "\(w) × \(h)", to: "\(width) × \(height)")
        rewritePage(edit) { text in
            BoardEdit.setAttribute(text, id: nil, name: "data-width", value: String(width)).flatMap {
                BoardEdit.setAttribute($0, id: nil, name: "data-height", value: String(height))
            }
        }
    }

    /// A change of a clip's time: the hand edit it is, and how it changes the page's text.
    typealias Timing = (edit: HandEdit, apply: (String) -> String?)

    /// Moves or trims a scene: its `data-start` and `data-duration` become the block's start and length.
    func retime(scene was: MotionTimeline.Clip, as now: MotionTimeline.Clip) {
        let change = sceneTiming(was, now)
        rewritePage(change.edit, change.apply)
    }

    /// Moves an element's animations by as much as its block moved on the timeline, or, for one animation trimmed,
    /// gives it the block's start and length. They are set on the element itself (`animation-delay`,
    /// `animation-duration`), over what its CSS rule says.
    func retime(_ was: MotionTimeline.Clip, as now: MotionTimeline.Clip) {
        let change = animationTiming(was, now)
        rewritePage(change.edit, change.apply)
    }

    /// Moves several clips at once, as one edit: a group dragged on the timeline.
    func retimeAll(_ moves: [(was: MotionTimeline.Clip, now: MotionTimeline.Clip)]) {
        let changes = moves.map {
            $0.was.delays.isEmpty ? sceneTiming($0.was, $0.now) : animationTiming($0.was, $0.now)
        }
        guard var edit = changes.first?.edit else { return }
        if changes.count > 1 { edit.what += " (and \(changes.count - 1) more)" }
        rewritePage(edit) { text in changes.reduce(Optional(text)) { text, change in text.flatMap(change.apply) } }
    }

    private func sceneTiming(_ was: MotionTimeline.Clip, _ now: MotionTimeline.Clip) -> Timing {
        let edit = HandEdit(
            board: pageFile, id: now.id, what: "data-start/data-duration",
            from: "\(Self.seconds(was.start))/\(Self.seconds(was.length))",
            to: "\(Self.seconds(now.start))/\(Self.seconds(now.length))")
        return (
            edit,
            { text in
                BoardEdit.setAttribute(text, id: now.id, name: "data-start", value: Self.seconds(now.start)).flatMap {
                    BoardEdit.setAttribute($0, id: now.id, name: "data-duration", value: Self.seconds(now.length))
                }
            }
        )
    }

    private func animationTiming(_ was: MotionTimeline.Clip, _ now: MotionTimeline.Clip) -> Timing {
        let shift = now.start - was.start
        let delays = was.delays.map { $0 + shift }
        let lengths = was.delays.count == 1 && now.length != was.length ? [now.length] : was.lengths
        let list = { (values: [Double]) in values.map { Self.seconds(max($0, 0)) + "s" }.joined(separator: ", ") }
        let edit = HandEdit(
            board: pageFile, id: now.id, what: "animation-delay/animation-duration",
            from: list(was.delays) + "/" + list(was.lengths), to: list(delays) + "/" + list(lengths))
        return (
            edit,
            { text in
                BoardEdit.setStyle(text, id: now.id, property: "animation-delay", value: list(delays)).flatMap {
                    BoardEdit.setStyle($0, id: now.id, property: "animation-duration", value: list(lengths))
                }
            }
        )
    }

    static func seconds(_ value: Double) -> String { String(format: "%g", (value * 100).rounded() / 100) }

    /// The page's file name, as hand edits name it.
    var pageFile: String { url.lastPathComponent }

    /// Changes the page's own text with `change` and saves it, keeping `edit` for the agent and for ⌘Z. It goes
    /// through the editor, so the source shown stays in step; the page is drawn again at the time it showed. When the
    /// element isn't found for sure, nothing changes and the banner says why.
    func rewritePage(_ edit: HandEdit, _ change: (String) -> String?) {
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

    /// Asks where to save the video, then records it as `options` say.
    func exportVideo(_ options: MotionExport) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.type]
        panel.nameFieldStringValue =
            url.deletingLastPathComponent().lastPathComponent + "." + (options.type.preferredFilenameExtension ?? "mp4")
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let to = panel.url else { return }
            Task { @MainActor in await self?.record(to: to, options) }
        }
    }

    /// Records the page from its first frame to its last into `to`, showing how far it got in the bar. The video
    /// opens in a tab when it's done.
    private func record(to: URL, _ options: MotionExport) async {
        do {
            guard
                let length = try await web.evaluateJavaScript("window.kelpMotion?.duration()", contentWorld: Self.world)
                    as? Double, length > 0,
                let stage = try await web.evaluateJavaScript("window.kelpMotion?.stage()", contentWorld: Self.world)
                    as? [Double], stage.count == 6
            else { throw RPCError.internalError("The page isn't a motion page.") }
            // The whole page, or only its work area.
            let span = options.onlyRange ? options.range ?? 0...length : 0...length
            let fps = options.rate, frames = Int(((span.upperBound - span.lowerBound) * fps).rounded(.up))
            let (w, h) = (Int(stage[4] * options.scale), Int(stage[5] * options.scale))
            let movie = options.format == .mp4 ? try MotionMovie(to, width: w, height: h) : nil
            let gif = options.format == .gif ? try MotionGIF(to, frames: frames + 1, fps: fps) : nil
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: stage[0], y: stage[1], width: stage[2], height: stage[3])
            // The picture is the size asked for in pixels, however small the pane shows the stage.
            config.snapshotWidth = NSNumber(value: Double(w) / Double(view.window?.backingScaleFactor ?? 2))
            for frame in 0...frames {
                motionStudio.exporting(frame, of: frames)
                let at = Double(frame) / fps
                _ = try await web.callAsyncJavaScript(
                    "return await window.kelpMotion.frameAt(at)", arguments: ["at": span.lowerBound + at],
                    contentWorld: Self.world)
                let image = try await web.takeSnapshot(configuration: config)
                guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                try await movie?.add(picture, at: at)
                gif?.add(picture)
            }
            try await movie?.finish(at: Double(frames + 1) / fps)
            try gif?.finish()
            runJS("window.kelpMotion?.done()")
            motionStudio.exporting(nil, of: frames)
            app.workbench.open(TabURI.file(to.path))
        } catch {
            runJS("window.kelpMotion?.done()")
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
