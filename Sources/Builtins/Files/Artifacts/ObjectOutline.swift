import CoreImage
import Foundation
import Vision

/// The object under a point of a picture, as its outline (Figma's object selection in images): Vision lifts the
/// picture's foreground objects apart, the one at the point is kept, and its edge is traced. On this Mac, no network.
enum ObjectOutline {
    /// The outline of the object at `point` (0–1 across and down `file`'s picture), as points 0–1 across and down, at
    /// most `limit` of them; nil when nothing stands out there.
    static func outline(of file: URL, at point: CGPoint, limit: Int = 160) throws -> [CGPoint]? {
        let handler = VNImageRequestHandler(url: file)
        let objects = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([objects])
        guard let found = objects.results?.first else { return nil }
        let labels = found.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let x = min(w - 1, max(0, Int(point.x * CGFloat(w)))), y = min(h - 1, max(0, Int(point.y * CGFloat(h))))
        let label = base.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(labels) + x, as: UInt8.self)
        guard label != 0 else { return nil }
        let mask = try found.generateScaledMaskForImage(forInstances: IndexSet(integer: Int(label)), from: handler)
        let edges = VNDetectContoursRequest()
        edges.maximumImageDimension = 512
        edges.detectsDarkOnLight = false
        try VNImageRequestHandler(cvPixelBuffer: mask).perform([edges])
        guard let contour = edges.results?.first?.topLevelContours.max(by: { $0.pointCount < $1.pointCount }) else {
            return nil
        }
        // Vision's points start at the bottom left: turned to go down from the top.
        let points = contour.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
        let step = max(1, points.count / limit)
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }
}
