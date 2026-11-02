import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers
import KelpKit

/// Read-only previews for files the editor shouldn't open: PDFs via PDFKit, images an `ImagePreview` (copyable),
/// everything else Quick Look can show.
@MainActor
enum Preview {
    static let pdf: Set<String> = ["pdf"]
    static let quickLook: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg", "ico",
        "mov", "mp4", "mp3", "wav", "key", "pages", "numbers", "docx", "xlsx", "pptx", "zip"]

    static func canPreview(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased(); return pdf.contains(e) || quickLook.contains(e)
    }

    static func view(for url: URL, app: AppModel) -> NSView {
        if pdf.contains(url.pathExtension.lowercased()), let doc = PDFDocument(url: url) {
            let v = LinkedPDFView(app: app)
            v.document = doc
            v.autoScales = true
            v.displayMode = .singlePageContinuous
            return v
        }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            return ImagePreview(image: image, url: url)
        }
        let q = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        q.previewItem = url as NSURL
        q.shouldCloseWithWindow = false
        return q
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
        if let rep = image.representations.first, rep.pixelsWide > 0 { image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        self.image = image
        imageScaling = .scaleProportionallyDown
        animates = true
        focusRingType = .none
        // Its size is the image's: at the default priority a big one would push the window past the screen.
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] { setContentCompressionResistancePriority(.defaultLow, for: o) }
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
    override func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action == #selector(copy(_:)) || super.validateMenuItem(item) }

    @objc func copy(_ sender: Any?) {
        let item = NSPasteboardItem()
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let type = UTType(filenameExtension: url.pathExtension), let data = FileManager.default.contents(atPath: url.path) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item])
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
