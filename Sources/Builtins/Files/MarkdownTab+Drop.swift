import AVFoundation
import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// Pictures and videos dropped from Finder on a canvas or a motion page. One dropped on an image (with a data-id)
/// replaces its picture. On a motion page's stage or timeline, one dropped elsewhere joins the page as a layer of its
/// own, from the time shown (or the second it was dropped at on the timeline), for three seconds or the video's
/// length, where it was dropped on the stage or in its middle. Each is copied beside the page first.
extension MarkdownTab {
    /// What the pointer does on the page beside the clicks: a pinch looks closer at a board, and files dropped from
    /// Finder come here first.
    func setUpPointer() {
        web.allowsMagnification = page == .canvas
        web.onFiles = { [weak self] files, at in self?.dropped(files, at: at) ?? false }
    }

    /// Whether the files are the tab's to take: pictures or videos, on a canvas or a motion page.
    func dropped(_ files: [URL], at point: NSPoint) -> Bool {
        guard page == .canvas || page == .motion, !files.isEmpty, files.allSatisfy(Self.isMedia) else { return false }
        Task { await drop(files, at: point) }
        return true
    }

    static func isMedia(_ file: URL) -> Bool {
        let type = UTType(filenameExtension: file.pathExtension)
        return type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true
    }

    private func drop(_ files: [URL], at point: NSPoint) async {
        let js = "window.kelpPointAt?.(\(point.x), \(point.y))"
        let hit: [String: Any]?
        do { hit = try await web.evaluateJavaScript(js, contentWorld: Self.world) as? [String: Any] } catch {
            hit = nil
        }
        let board = hit?["board"] as? String, id = hit?["id"] as? String ?? ""
        if let board, hit?["image"] as? Bool == true, !id.isEmpty, let file = files.first,
            UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        {
            return await setImage(board, id, to: file)
        }
        guard page == .motion else {
            return Banner.show(String(localized: "Drop a picture on an image with a data-id to replace it."))
        }
        let at = hit.flatMap { h in (h["x"] as? Double).flatMap { x in (h["y"] as? Double).map { (x, $0) } } }
        for file in files { await addMedia(file, at: at, time: motionStudio.at) }
    }

    /// Copies `file` beside the motion page and adds it as its own clip from `time`, centred on `at` in the stage's
    /// points (its middle when nil).
    func addMedia(_ file: URL, at: (Double, Double)?, time: Double) async {
        let folder = url.deletingLastPathComponent().path
        guard let copied = await app.call(FilesCopy(paths: [file.path], into: folder)) else { return }
        guard let path = copied.made.first else {
            return Banner.show(copied.error ?? String(localized: "Couldn’t copy the file."), style: .error)
        }
        let name = (path as NSString).lastPathComponent
        guard !name.contains(where: { "\"<>&".contains($0) }) else {
            return Banner.show(String(localized: "Rename “\(name)” without quotes or < > &, then drop it again."))
        }
        let video = UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true
        let (stageW, stageH) = MotionPage.size(editor.text)
        var size = NSSize(width: Double(stageW) / 2, height: Double(stageW) / 2 * 9 / 16)
        var length = 3.0
        if video {
            do { length = max(try await AVURLAsset(url: file).load(.duration).seconds, 0.1) } catch {
                length = 5   // a video AVFoundation can't read stays five seconds; its clip can be trimmed
            }
        } else if let rep = NSImageRep(contentsOf: file), rep.pixelsWide > 0 {
            let w = min(Double(rep.pixelsWide), Double(stageW) / 2)
            size = NSSize(width: w, height: w * Double(rep.pixelsHigh) / Double(rep.pixelsWide))
        }
        let (x, y) = at ?? (Double(stageW) / 2, Double(stageH) / 2)
        let id = BoardEdit.freeID(editor.text, video ? "video" : "img")
        let place =
            "position: absolute; left: \(Int(x - size.width / 2))px; top: \(Int(y - size.height / 2))px; "
            + "width: \(Int(size.width))px"
        let times = "data-start=\"\(Self.seconds(time))\" data-duration=\"\(Self.seconds(length))\""
        let attributes = "data-id=\"\(id)\" data-title=\"\(name)\" \(times) src=\"\(name)\" style=\"\(place)\""
        let html = video ? "<video \(attributes) muted playsinline></video>" : "<img \(attributes)>"
        rewritePage(HandEdit(board: url.lastPathComponent, id: id, what: "added", from: nil, to: name)) {
            BoardEdit.appendToBody($0, html)
        }
    }
}
