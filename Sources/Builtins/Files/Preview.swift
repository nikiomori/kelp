import AppKit
import Core
import KelpKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Read-only previews for files the editor shouldn't open: PDFs via PDFKit, images an `ImagePreview` (copyable),
/// everything else Quick Look can show.
@MainActor
enum Preview {
    static let pdf: Set<String> = ["pdf"]
    static let quickLook: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg", "ico",
        "mov", "mp4", "mp3", "wav", "key", "pages", "numbers", "docx", "xlsx", "pptx", "zip"
    ]

    static func canPreview(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pdf.contains(pathExtension) || quickLook.contains(pathExtension)
    }

    static func view(for url: URL, app: AppModel) -> NSView {
        if pdf.contains(url.pathExtension.lowercased()), let doc = PDFDocument(url: url) {
            let pdfView = LinkedPDFView(app: app)
            pdfView.document = doc
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            return pdfView
        }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
            let image = NSImage(contentsOf: url)
        {
            return ImagePreview(image: image, url: url)
        }
        let quickLookView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        quickLookView.previewItem = url as NSURL
        quickLookView.shouldCloseWithWindow = false
        return quickLookView
    }
}

/// A file's preview that follows the file: written over (a new render of a video, an image), it's built again, since
/// Quick Look, PDFKit and an image read once keep showing the old one. Gone, it stays as shown.
@MainActor
final class FollowedPreview {
    let view = NSView()
    private(set) var shown: NSView
    /// The version shown: nil until the daemon pushes the first, which is the one already shown.
    private var stamp: FileStamp?
    private let version: Watched

    init(url: URL, app: AppModel) {
        shown = Preview.view(for: url, app: app)
        view.pin(shown)
        version = Watched(.file, in: app)
        version.key = url.path
        track(owner: self) {
            app.latest(FileEvent.self, url.path)?.stamp
        } changed: { [weak self] now in
            guard let self, let now, now != stamp else { return }
            defer { stamp = now }
            if stamp != nil { show(Preview.view(for: url, app: app)) }
        }
    }

    private func show(_ next: NSView) {
        let focused = shown.window?.firstResponder === shown
        (shown as? QLPreviewView)?.close()   // or its player keeps playing the old file
        shown.removeFromSuperview()
        shown = next
        view.pin(next)
        if focused { next.window?.makeFirstResponder(next) }
    }
}

/// An image as a tab, like Xcode's: at most its own size, centered. ⌘C or Copy Image in its menu puts it on the
/// pasteboard as the file's own bytes (a GIF keeps its frames) and as PNG for apps (and agents) that only read that.
@MainActor
final class ImagePreview: NSImageView {
    private let url: URL

    init(image: NSImage, url: URL) {
        self.url = url
        super.init(frame: .zero)
        // A pixel is a point, as in a browser: NSImage would size it by the file's DPI (a 72-dpi-less PNG comes out huge).
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        self.image = image
        imageScaling = .scaleProportionallyDown
        animates = true
        focusRingType = .none
        // Its size is the image's: at the default priority a big one would push the window past the screen.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentCompressionResistancePriority(.defaultLow, for: orientation)
        }
        menu = NSMenu()
        menu?.add(String(localized: "Copy Image")) { [weak self] in self?.copy(nil) }
        if let menu {
            menu.addItem(.separator())
            WorkspaceActions.addLocate(to: menu, path: url.path)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) || super.validateMenuItem(item)
    }

    @objc func copy(_ sender: Any?) {
        let item = NSPasteboardItem()
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        {
            item.setData(png, forType: .png)
        }
        if let type = UTType(filenameExtension: url.pathExtension),
            let data = FileManager.default.contents(atPath: url.path)
        {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}

/// Links clicked in a PDF go by the preview's rules (`PreviewLinks.target`): a repo's PDF can link to an app it ships
/// or to another app's scheme, and PDFKit on its own would open either.
@MainActor
final class PDFLinks: NSObject, @MainActor PDFViewDelegate {
    private let app: AppModel
    init(app: AppModel) { self.app = app }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { PreviewLinks.open(url, in: app) }
}

/// A PDF with its links' delegate, which it keeps (PDFView holds its delegate weakly, and asks it what it answers: a
/// view that were its own delegate would ask itself forever).
@MainActor
final class LinkedPDFView: PDFView {
    let links: PDFLinks
    init(app: AppModel) {
        links = PDFLinks(app: app)
        super.init(frame: .zero)
        delegate = links   // without a delegate PDFKit opens any link with its app
    }
    required init?(coder: NSCoder) { fatalError() }
}
