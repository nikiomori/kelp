import AVFoundation
import CoreGraphics

/// Writes a movie frame by frame through AVAssetWriter, each frame drawn into a 32-bit BGRA buffer from the encoder's
/// pool, in sRGB. Made with the file; `open` sets the codec and size (a recording knows them at its first frame). A
/// realtime writer (a recording) tells the encoder so and drops a frame while it's busy; a movie made from a page
/// waits until it's `ready` instead. Kept inside the actor that writes, which owns it.
package final class FrameWriter {
    package let writer: AVAssetWriter
    package private(set) var width = 0, height = 0
    private var input: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    package init(_ url: URL, type: AVFileType) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}   // it writes only new
        writer = try AVAssetWriter(outputURL: url, fileType: type)
    }

    package var opened: Bool { input != nil }
    /// Whether the encoder takes a frame now.
    package var ready: Bool { input?.isReadyForMoreMediaData == true }

    /// Starts the movie at `width` × `height`; `settings` are the rest of its output settings (the codec, …).
    package func open(width: Int, height: Int, settings: [String: Any], realtime: Bool) {
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings.merging([AVVideoWidthKey: width, AVVideoHeightKey: height]) { $1 })
        input.expectsMediaDataInRealTime = realtime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        (self.input, self.width, self.height) = (input, width, height)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    /// Adds the frame `draw` draws at `time` seconds; false when the encoder had no buffer for it.
    package func add(at time: Double, _ draw: (CGContext) -> Void) -> Bool {
        guard let adaptor, let pool = adaptor.pixelBufferPool else { return false }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
            return false
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        {
            draw(context)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
        return true
    }

    /// Ends the movie at `time` seconds; the caller then awaits the writer's `finishWriting`.
    package func end(at time: Double) -> AVAssetWriter {
        input?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        return writer
    }
}
