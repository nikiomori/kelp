import AVFoundation
import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers
import WebKit
import WorkbenchKit

/// A motion page in its tab: the bar under the page's bar follows its time (`MotionBar`), and Export Video records the
/// page, a frame at a time, as an MP4.
extension MarkdownTab {
    /// The frames a second of an exported video.
    static let videoFPS = 30.0

    func makeMotionStudio() -> MotionStudio {
        let made = MotionStudio { [weak self] call in self?.runJS(call) }
        made.onExport = { [weak self] in self?.exportVideo() }
        made.onScene = { [weak self] id, start, length in self?.retime(scene: id, start: start, length: length) }
        return made
    }

    func motionMessage(_ body: [String: Any]) {
        let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue ?? 0 }
        let clips = { (key: String, start: String, length: String) in
            (body[key] as? [[String: Any]] ?? []).map { c in
                let begins = (c[start] as? NSNumber)?.doubleValue ?? 0
                let takes = (c[length] as? NSNumber)?.doubleValue ?? 0
                return MotionTimeline.Clip(
                    id: c["id"] as? String ?? "", title: c["title"] as? String ?? "", start: begins,
                    length: length == "end" ? takes - begins : takes)
            }
        }
        motionStudio.show(
            MotionStudio.State(
                at: number("t"), length: number("duration"), playing: body["playing"] as? Bool ?? false,
                width: Int(number("width")), height: Int(number("height")),
                scenes: clips("scenes", "start", "duration"), tracks: clips("tracks", "start", "end")))
    }

    /// Moves or trims scene `id` to start at `start` and last `length` seconds, in the page's file: the page is drawn
    /// again at the time it showed.
    func retime(scene id: String, start: Double, length: Double) {
        let seconds = { (value: Double) in String(format: "%g", (value * 100).rounded() / 100) }
        guard
            let moved = BoardEdit.setAttribute(editor.text, id: id, name: "data-start", value: seconds(start)),
            let both = BoardEdit.setAttribute(moved, id: id, name: "data-duration", value: seconds(length))
        else {
            return Banner.show(String(localized: "Couldn’t find scene \(id) in the page as it is now."), style: .error)
        }
        editor.apply(text: both, selection: NSRange(location: 0, length: 0))
        Task { _ = await saveFile?() }
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
