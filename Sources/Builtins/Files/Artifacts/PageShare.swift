import AppKit
import Core
import DesignKit
import KelpKit
import WebKit

/// A page passed on as a Mac document is: ⋯ › Share… offers the system's services (Mail, Messages, AirDrop) with the
/// page as people read it (a doc, slides or a deck as a PDF, a design's boards as pictures, any other page as one
/// HTML file), made in a temporary folder; and a board or a slide is copied as a picture to paste anywhere.
extension MarkdownTab {
    /// What Share offers for this page.
    private var shared: PageExport {
        switch page {
        case .markdown, .slides: .pdf
        case .canvas: isDeck ? .pdf : .png
        default: .html
        }
    }

    /// Makes the page's shared file(s) and shows the services beside `view`.
    func share(from anchor: NSView) {
        let name = url.deletingLastPathComponent().lastPathComponent, format = shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-share-\(UUID().uuidString)")
        let to = format.type == nil ? folder : folder.appendingPathComponent(name + "." + format.rawValue)
        Task {
            guard await export(format, to: to, reveal: false) else { return }
            // The boards' pictures are named as `exportBoards` names them.
            let boards = ArtifactCanvas.read(editor.text)?.boards.map {
                folder.appendingPathComponent(
                    (($0.file as NSString).lastPathComponent as NSString).deletingPathExtension + ".png")
            }
            let items = format.type == nil ? boards ?? [] : [to]
            guard !items.isEmpty else { return }
            NSSharingServicePicker(items: items).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    /// The page as one HTML file in the default browser: at its own width, on another screen or in a call.
    func openInBrowser() {
        let name = url.deletingLastPathComponent().lastPathComponent
        let to = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-open-\(UUID().uuidString)")
            .appendingPathComponent(name + ".html")
        Task {
            guard await export(.html, to: to, reveal: false) else { return }
            PreviewLinks.openInBrowser(to)
        }
    }

    /// Board `board` of the canvas, as it is drawn, copied as a picture.
    func copyBoard(_ board: String) {
        guard let found = ArtifactCanvas.read(editor.text)?.boards.first(where: { $0.file == board }) else { return }
        let file = url.deletingLastPathComponent().appendingPathComponent(board)
        Task {
            do {
                let png = try await Self.picture(
                    of: file, width: Double(found.w ?? 1280), height: found.h.map(Double.init))
                Self.copy(png)
            } catch {
                Banner.show(
                    String(localized: "Couldn’t copy the picture: \(error.localizedDescription)"), style: .error)
            }
        }
    }

    /// Slide `i` as the page shows it, copied as a picture.
    func copySlide(_ i: Int) {
        Task {
            do {
                let box = try await web.callAsyncJavaScript(
                    "const b = kelpSlides[i]?.getBoundingClientRect(); return b ? [b.x, b.y, b.width, b.height] : null",
                    arguments: ["i": i], contentWorld: Self.world)
                guard let b = box as? [Double], b.count == 4,
                    let png = try await slidePNG(
                        CGRect(x: b[0], y: b[1], width: b[2], height: b[3]), height: Int(1920 * b[3] / max(b[2], 1)))
                else { return }
                Self.copy(png)
            } catch {
                Banner.show(
                    String(localized: "Couldn’t copy the picture: \(error.localizedDescription)"), style: .error)
            }
        }
    }

    private static func copy(_ png: Data) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
    }
}
