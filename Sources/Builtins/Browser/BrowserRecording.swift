// Records the page as a video or a GIF, started by `kelp browser record` or ⋯ › Record Video / Record GIF. The red
// button stops it.
import AVFoundation
import AppKit
import Core
import ImageIO
import KelpKit
import UniformTypeIdentifiers
import WebKit

extension BrowserTab {
    /// Handles `kelp browser record [file] | record stop`. It answers with the file's path: where the recording goes,
    /// or where it went.
    func record(_ args: JSONValue) async throws -> JSONValue {
        if args["stop"]?.bool == true {
            guard recording != nil else {
                throw RPCError.invalidParams(
                    "Not recording: kelp browser record [file.mp4|file.gif] starts one."
                        + (lastRecording.map { " The last one (stopped by the user, or at 10 minutes) is \($0.path)" }
                            ?? ""))
            }
            return .object(["path": .string(try await stopRecording().path)])
        }
        let to =
            args["path"]?.string.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "kelp-recording-\(UUID().uuidString.prefix(6)).mp4")
        try startRecording(to, byAgent: true)
        return .object(["path": .string(to.path), "recording": .bool(true)])
    }

    /// Starts a recording from ⋯ › Record Video / Record GIF. It goes into ~/Downloads, as the page's downloads do.
    func recordFromMenu(gif: Bool) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = String(localized: "Kelp Recording \(stamp.string(from: Date()))") + (gif ? ".gif" : ".mp4")
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        do { try startRecording(dir.appendingPathComponent(name), byAgent: false) } catch {
            Banner.show(AppModel.message(error), style: .error)
        }
    }

    /// An agent's recording leaves out what the page shows while the user has it (they may be signing in).
    private func startRecording(_ to: URL, byAgent: Bool) throws {
        guard recording == nil else {
            throw RPCError.invalidParams("Already recording this page: kelp browser record stop ends it.")
        }
        let rec = try PageRecording(to: to)
        recording = rec
        recordButton.isHidden = false
        rec.run(web) { [weak self] in
            byAgent && self?.drive?.takenOver == true
        } ended: { [weak self] in
            self?.saveRecording()
        }
    }

    /// Saves the recording when the red button or the menu stops it, at 10 minutes, or when the tab closes, and shows a
    /// banner that can show the file in Finder.
    @objc func saveRecording() {
        Task {
            do {
                let url = try await stopRecording()
                Banner.show(
                    String(localized: "Recorded \(url.lastPathComponent)"),
                    action: (
                        String(localized: "Reveal in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    ))
            } catch {
                Banner.show(AppModel.message(error), style: .error)
            }
        }
    }

    private func stopRecording() async throws -> URL {
        guard let rec = recording else { throw RPCError.invalidParams("Not recording") }
        recording = nil
        recordButton.isHidden = true
        try await rec.finish()
        lastRecording = rec.to
        return rec.to
    }
}

/// Records frames of a page as WebKit draws them, and writes them as it goes: H.264 for .mp4 and .mov, a GIF for .gif.
/// The first frame sets the size, and a page resized later is fitted into it, at the top and centred across.
/// Limit: a tab off screen isn't drawn, so its picture stands still (or isn't taken) until it's shown.
@MainActor
final class PageRecording {
    nonisolated static let fps = 10.0, longest: TimeInterval = 600
    nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let to: URL
    private let sink: FrameSink
    private var loop: Task<Void, Never>?
    private let start = Date()

    init(to: URL) throws {
        self.to = to
        switch to.pathExtension.lowercased() {
        case "gif": sink = try GIFSink(to)
        case "mp4": sink = try MovieSink(to, .mp4)
        case "mov": sink = try MovieSink(to, .mov)
        default: throw RPCError.invalidParams("A recording is a .mp4, .mov or .gif file, not \(to.lastPathComponent)")
        }
    }

    /// Takes a frame of `web` every 1/fps s, but none while `paused`, and calls `ended` once it has run for `longest`.
    func run(_ web: WKWebView, paused: @escaping () -> Bool, ended: @escaping () -> Void) {
        loop = Task { [weak web, start, sink] in
            while !Task.isCancelled, let web, Date().timeIntervalSince(start) < Self.longest {
                let now = Date()
                // When there is no picture this time (WebKit had none to give), the last frame lasts longer.
                if !paused(), let image = await Self.picture(of: web),
                    let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                {
                    await sink.add(frame, at: now.timeIntervalSince(start))
                }
                do {
                    try await Task.sleep(for: .seconds(max(0.02, 1 / Self.fps - Date().timeIntervalSince(now))))
                } catch {
                    break   // stopped
                }
            }
            if !Task.isCancelled { ended() }
        }
    }

    private static func picture(of web: WKWebView) async -> NSImage? {
        do { return try await web.takeSnapshot(configuration: nil) } catch { return nil }
    }

    func finish() async throws {
        loop?.cancel()
        await loop?.value
        try await sink.finish(at: Date().timeIntervalSince(start))
    }

    /// Returns the frame size for the first picture: its longer side at most `most`, and both sides even, because H.264
    /// needs that.
    nonisolated static func size(of image: CGImage, most: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(most) / Double(max(image.width, image.height, 1)))
        return (max(2, Int(Double(image.width) * scale) & ~1), max(2, Int(Double(image.height) * scale) & ~1))
    }

    /// Draws `image` on white, fitted into `ctx` at the top and centred across.
    nonisolated static func draw(_ image: CGImage, in ctx: CGContext) {
        let box = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.setFillColor(.white)
        ctx.fill(box)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (box.width - w) / 2, y: box.height - h, width: w, height: h))
    }
}

/// Writes frames off the main thread, because drawing and encoding a frame, and finishing a GIF, take a while at 10
/// frames a second.
private protocol FrameSink: Actor {
    func add(_ image: CGImage, at time: TimeInterval)
    func finish(at time: TimeInterval) async throws
}

/// The error when no frame came, because the tab wasn't on screen or the user had the page the whole time.
private let nothingRecorded = RPCError.internalError(
    "Nothing was recorded: the page’s tab wasn’t on screen. Show it and record again.")

private actor MovieSink: FrameSink {
    private let file: FrameWriter
    private var first: TimeInterval?

    init(_ url: URL, _ type: AVFileType) throws { file = try FrameWriter(url, type: type) }

    func add(_ image: CGImage, at time: TimeInterval) {
        if !file.opened {
            let size = PageRecording.size(of: image, most: 1920)
            file.open(
                width: size.width, height: size.height, settings: [AVVideoCodecKey: AVVideoCodecType.h264],
                realtime: true)
        }
        guard file.writer.status == .writing, file.ready,
            file.add(at: time - (first ?? time), { PageRecording.draw(image, in: $0) })
        else { return }
        first = first ?? time
    }

    func finish(at time: TimeInterval) async throws {
        guard let first, file.writer.status == .writing else {
            file.writer.cancelWriting()
            throw nothingRecorded
        }
        let writer = file.end(at: time - first)   // the last frame lasts until the stop
        await withCheckedContinuation { done in writer.finishWriting { done.resume() } }
        guard writer.status == .completed else {
            throw RPCError.internalError("Couldn’t write the video: \(writer.error?.localizedDescription ?? "")")
        }
    }
}

/// Writes a GIF. A frame the same as the one before only makes that one last longer, so a page that sits still costs
/// nothing.
private actor GIFSink: FrameSink {
    private let file: CGImageDestination
    private var size: (width: Int, height: Int)?
    private var held: (image: CGImage, bytes: Data?, at: TimeInterval)?
    private var frames = 0

    init(_ url: URL) throws {
        guard
            let file = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, Int(PageRecording.longest * PageRecording.fps) + 1, nil
            )
        else { throw RPCError.internalError("Can’t write \(url.path)") }
        CGImageDestinationSetProperties(
            file, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        self.file = file
    }

    func add(_ image: CGImage, at time: TimeInterval) {
        let size = size ?? PageRecording.size(of: image, most: 960)   // a GIF the size of a Retina page is huge
        self.size = size
        guard
            let ctx = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: PageRecording.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return }
        PageRecording.draw(image, in: ctx)
        guard let small = ctx.makeImage() else { return }
        let bytes = small.dataProvider?.data as Data?
        if let held, held.bytes == bytes { return }
        put(until: time)
        held = (small, bytes, time)
    }

    /// Writes the held frame, lasting until `time`.
    private func put(until time: TimeInterval) {
        guard let held else { return }
        let delay = max(0.05, time - held.at)
        let gif = [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
        CGImageDestinationAddImage(file, held.image, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        frames += 1
    }

    func finish(at time: TimeInterval) async throws {
        put(until: time)
        guard frames > 0 else { throw nothingRecorded }
        guard CGImageDestinationFinalize(file) else { throw RPCError.internalError("Couldn’t write the GIF") }
    }
}
