import AppKit
import Core
import ImageIO
import KelpKit
import UniformTypeIdentifiers
import WebKit
import WorkbenchKit

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

    /// Frame as PNG…: asks where, then saves the frame shown now at the stage's own size (a poster, a thumbnail).
    func saveFrame() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue =
            url.deletingLastPathComponent().lastPathComponent + " " + MotionStudio.clock(motionStudio.at) + ".png"
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let to = panel.url else { return }
            Task { @MainActor in await self?.writeFrame(to) }
        }
    }

    private func writeFrame(_ to: URL) async {
        do {
            guard
                let stage = try await web.evaluateJavaScript("window.kelpMotion?.stage()", contentWorld: Self.world)
                    as? [Double], stage.count == 6
            else { throw RPCError.internalError("The page isn't a motion page.") }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: stage[0], y: stage[1], width: stage[2], height: stage[3])
            config.snapshotWidth = NSNumber(value: stage[4] / Double(view.window?.backingScaleFactor ?? 2))
            guard let picture = try await framePicture(config, transparent: false, Int(stage[4]), Int(stage[5])),
                let file = CGImageDestinationCreateWithURL(to as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(file, picture, nil)
            guard CGImageDestinationFinalize(file) else { throw CocoaError(.fileWriteUnknown) }
            app.workbench.open(TabURI.file(to.path))
        } catch {
            Banner.show(String(localized: "Couldn’t save the frame: \(error.localizedDescription)"), style: .error)
        }
    }
}
