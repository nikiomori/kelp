import AVFoundation
import AppKit
import Core
import KelpKit

/// Writes frames given one at a time, each at its own time, as an H.264 MP4 (at a quality), or as a ProRes 4444 MOV
/// that keeps their transparency. Unlike a recording, it waits for the encoder rather than drop a frame.
actor MotionMovie {
    private let file: FrameWriter

    init(_ url: URL, width: Int, height: Int, options: MotionExport) throws {
        let mov = options.format == .mov
        file = try FrameWriter(url, type: mov ? .mov : .mp4)
        // H.264 takes even sizes.
        let width = max(2, width / 2 * 2), height = max(2, height / 2 * 2)
        var settings: [String: Any] = [AVVideoCodecKey: mov ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264]
        // Bits a pixel a frame: Good and Small make a smaller file than the encoder's own choice.
        let bits = ["good": 0.1, "small": 0.04][options.quality.rawValue]
        if !mov, let bits {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(Double(width * height) * options.rate * bits)
            ]
        }
        file.open(width: width, height: height, settings: settings, realtime: false)
    }

    func add(_ image: CGImage, at time: Double) async throws {
        while !file.ready {
            guard file.writer.status == .writing else { throw file.writer.error ?? CocoaError(.fileWriteUnknown) }
            await Task.yield()
        }
        let whole = CGRect(x: 0, y: 0, width: file.width, height: file.height)
        let added = file.add(at: time) { context in
            context.interpolationQuality = .high
            // The pool hands buffers back with the frame before in them: a clear frame would show through to it.
            context.clear(whole)
            context.draw(image, in: whole)
        }
        guard added else { throw file.writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func finish(at time: Double) async throws {
        let writer = file.end(at: time)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
