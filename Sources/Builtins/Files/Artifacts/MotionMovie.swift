import AVFoundation
import AppKit
import Core

/// Writes frames given one at a time, each at its own time, as an H.264 MP4 (at a quality), or as a ProRes 4444 MOV
/// that keeps their transparency. Unlike a recording, it waits for the encoder rather than drop a frame.
actor MotionMovie {
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
