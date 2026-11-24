import AppKit
import WebKit

extension MarkdownTab {
    /// The frame shown, as a picture; a transparent video's from two, on black and on white (`MotionExports.matte`).
    func framePicture(_ config: WKSnapshotConfiguration, transparent: Bool, _ w: Int, _ h: Int) async throws
        -> CGImage?
    {
        guard transparent else {
            return try await web.takeSnapshot(configuration: config).cgImage(
                forProposedRect: nil, context: nil, hints: nil)
        }
        var shots: [CGImage] = []
        for colour in ["#000", "#fff"] {
            _ = try await web.callAsyncJavaScript(
                "window.kelpMotion.matte(c);"
                    + "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                arguments: ["c": colour], contentWorld: Self.world)
            if let shot = try await web.takeSnapshot(configuration: config).cgImage(
                forProposedRect: nil, context: nil, hints: nil)
            {
                shots.append(shot)
            }
        }
        guard shots.count == 2 else { return nil }
        return MotionExports.matte(black: shots[0], white: shots[1], width: w, height: h)
    }
}
