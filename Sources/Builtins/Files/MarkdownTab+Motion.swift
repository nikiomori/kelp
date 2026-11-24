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
        made.onSaveFrame = { [weak self] in self?.saveFrame() }
        made.onTypedCaptions = { [weak self] in self?.typedCaptions() }
        made.onChoose = { [weak self] id in self?.chooseOnStage(id) }
        made.onRemove = { [weak self] id in self?.removeElement(MotionPage.board, id) }
        made.onHide = { [weak self] id, hide in self?.hideElement(id, hide) }
        made.onFormat = { [weak self] w, h in self?.resizeStage(w, h) }
        made.onAdapt = { [weak self] in self?.askAdaptations() }
        made.onGroup = { [weak self] moves in self?.retimeAll(moves) }
        made.onKeyframe = { [weak self] in self?.keyframe() }
        made.marking = marking
        made.keyframes { k in
            k.onMove = { [weak self] id, from, to in self?.moveKeyframe(id, from: from, to: to) }
            k.menu = { [weak self] id, place in self?.keyframeMenu(id, place) }
            k.seamMenu = { [weak self] out, into in self?.seamMenu(out, into) }
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

    func motionMessage(_ body: [String: Any]) {
        followSound(playing: body["playing"] as? Bool ?? false, at: (body["t"] as? NSNumber)?.doubleValue ?? 0)
        let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue ?? 0 }
        let clips = { (key: String, start: String, length: String) in
            (body[key] as? [[String: Any]] ?? []).map { c in
                let begins = (c[start] as? NSNumber)?.doubleValue ?? 0
                let takes = (c[length] as? NSNumber)?.doubleValue ?? 0
                var clip = MotionTimeline.Clip(
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
                clip.transition = (c["trans"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let sound = c["sound"] as? String {
                    clip.wave = self.wave(
                        of: sound, from: (c["from"] as? NSNumber)?.doubleValue ?? 0, length: clip.length)
                }
                return clip
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
                }, captions: clips("captions", "start", "duration"), beats: pageBeats()))
    }

    /// Gives the stage another shape: the body's `data-width` and `data-height`. The page's own layout is the
    /// user's or the agent's to fit to it.
    func resizeStage(_ width: Int, _ height: Int) {
        let (w, h) = MotionPage.size(editor.text)
        let edit = HandEdit(board: pageFile, id: "body", what: "size", from: "\(w) × \(h)", to: "\(width) × \(height)")
        let reframe = motionStudio.reframe
        rewritePage(edit) { text in
            BoardEdit.setAttribute(text, id: nil, name: "data-width", value: String(width)).flatMap {
                BoardEdit.setAttribute($0, id: nil, name: "data-height", value: String(height))
            }.map { reframe.apply($0, old: (w, h), width: width, height: height) }
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

    /// Records the page into `to` as `format` with the options last used (`kelp artifact export`), listed under
    /// Export like one the user made.
    func exportVideo(to: URL, format: MotionExport.Format) {
        var options = motionStudio.exportOptions
        options.format = format
        let item = MotionExports.Item(to)
        motionStudio.exports.insert(item, at: 0)
        item.task = Task { await record(to: to, options, item) }
    }

    /// Asks where to save the video, then records it as `options` say.
    func exportVideo(_ options: MotionExport) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.type]
        panel.nameFieldStringValue =
            url.deletingLastPathComponent().lastPathComponent + "." + (options.type.preferredFilenameExtension ?? "mp4")
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let to = panel.url, let self else { return }
            let item = MotionExports.Item(to)
            motionStudio.exports.insert(item, at: 0)
            item.task = Task { @MainActor in await self.record(to: to, options, item) }
        }
    }

    /// Records the page from its first frame to its last into `to`, showing how far it got in the bar. The video
    /// opens in a tab when it's done.
    private func record(to: URL, _ options: MotionExport, _ item: MotionExports.Item) async {
        do {
            guard
                let length = try await web.evaluateJavaScript("window.kelpMotion?.duration()", contentWorld: Self.world)
                    as? Double, length > 0,
                let stage = try await web.evaluateJavaScript("window.kelpMotion?.stage()", contentWorld: Self.world)
                    as? [Double], stage.count == 6
            else { throw RPCError.internalError("The page isn't a motion page.") }
            // The whole page, or only its work area.
            let span = options.onlyRange ? options.range ?? 0...length : 0...length
            let warnings =
                try await web.evaluateJavaScript("window.kelpMotion.preflight()", contentWorld: Self.world)
                as? [String] ?? []
            let fps = options.rate, frames = Int(((span.upperBound - span.lowerBound) * fps).rounded(.up))
            let (w, h) = (Int(stage[4] * options.scale), Int(stage[5] * options.scale))
            let movie = options.format == .gif ? nil : try MotionMovie(to, width: w, height: h, options: options)
            let gif = options.format == .gif ? try MotionGIF(to, frames: frames + 1, fps: fps, once: options.once) : nil
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: stage[0], y: stage[1], width: stage[2], height: stage[3])
            // The picture is the size asked for in pixels, however small the pane shows the stage.
            config.snapshotWidth = NSNumber(value: Double(w) / Double(view.window?.backingScaleFactor ?? 2))
            for frame in 0...frames {
                try Task.checkCancellation()
                motionStudio.exporting(frame, of: frames)
                item.progress = Double(frame) / Double(max(frames, 1))
                let at = Double(frame) / fps
                // The first frame is the cover's, when one is chosen.
                let shown = frame == 0 ? options.cover ?? span.lowerBound : span.lowerBound + at
                _ = try await web.callAsyncJavaScript(
                    "return await window.kelpMotion.frameAt(at)", arguments: ["at": shown], contentWorld: Self.world)
                guard let picture = try await framePicture(config, transparent: options.format == .mov, w, h)
                else { continue }
                try await movie?.add(picture, at: at)
                gif?.add(picture)
            }
            try await movie?.finish(at: Double(frames + 1) / fps)
            try gif?.finish()
            // The page's sounds, mixed in after the frames (a GIF has none).
            let sounds =
                options.format == .gif
                ? []
                : MotionSound.sounds(in: editor.text, folder: url.deletingLastPathComponent(), from: span.lowerBound)
            if !sounds.isEmpty {
                let mixed = to.deletingLastPathComponent().appendingPathComponent(
                    ".kelp-mixing-" + to.lastPathComponent)
                if try await MotionSound.mix(to, sounds: sounds, into: mixed) {
                    _ = try FileManager.default.replaceItemAt(to, withItemAt: mixed)
                }
            }
            runJS("window.kelpMotion?.done()")
            motionStudio.exporting(nil, of: frames)
            let verdict = await MotionVerify.check(
                to, .init(width: w, height: h, fps: fps, duration: Double(frames + 1) / fps, sound: !sounds.isEmpty),
                warnings: warnings)
            item.verdict = verdict
            item.progress = nil
            leaveCheck(verdict, for: to)
            await writeSRT(beside: to)
            app.workbench.open(TabURI.file(to.path))
        } catch {
            runJS("window.kelpMotion?.done()")
            motionStudio.exporting(nil, of: 0)
            item.progress = nil
            if error is CancellationError {   // Cancel: the half-made file goes, and so does its row
                motionStudio.exports.removeAll { $0 === item }
                do { try FileManager.default.removeItem(at: to) } catch { return }   // none was written yet
                return
            }
            item.failure = error.localizedDescription
            leaveCheck(
                MotionVerify(
                    file: to.lastPathComponent, ok: false, width: 0, height: 0, fps: 0, duration: 0, audio: false,
                    problems: [error.localizedDescription], warnings: []), for: to)
            Banner.show(
                String(localized: "Couldn’t make the video: \(error.localizedDescription)"), style: .error)
        }
    }
}

/// Writes frames given one at a time, each at its own time, as an H.264 MP4 (at a quality), or as a ProRes 4444 MOV
/// that keeps their transparency. Unlike a recording, it waits for the encoder rather than drop a frame.
private actor MotionMovie {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int

    init(_ url: URL, width: Int, height: Int, options: MotionExport) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}   // it writes only new
        // H.264 takes even sizes.
        self.width = max(2, width / 2 * 2)
        self.height = max(2, height / 2 * 2)
        let mov = options.format == .mov
        writer = try AVAssetWriter(outputURL: url, fileType: mov ? .mov : .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: mov ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264,
            AVVideoWidthKey: self.width, AVVideoHeightKey: self.height
        ]
        // Bits a pixel a frame: Good and Small make a smaller file than the encoder's own choice.
        let bits = ["good": 0.1, "small": 0.04][options.quality.rawValue]
        if !mov, let bits {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(Double(self.width * self.height) * options.rate * bits)
            ]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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
            // The pool hands buffers back with the frame before in them: a clear frame would show through to it.
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
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
