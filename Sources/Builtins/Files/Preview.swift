import AppKit
import Core
import DesignKit
import KelpKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Read-only previews for files the editor shouldn't open: PDFs through PDFKit, images in an `ImagePreview` (which can
/// be copied), and everything else that Quick Look can show.
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

    /// Returns the preview view for `url`. A PDF's or image's bytes are read off the main thread, so a file on a slow
    /// volume can't stall the window.
    static func view(for url: URL, app: AppModel) async -> NSView {
        let isPDF = pdf.contains(url.pathExtension.lowercased()),
            isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        let bytes =
            isPDF || isImage ? await Task.detached { FileManager.default.contents(atPath: url.path) }.value : nil
        if isPDF, let bytes, let doc = PDFDocument(data: bytes) {
            let pdfView = LinkedPDFView(app: app)
            pdfView.document = doc
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            return pdfView
        }
        if isImage, let bytes, let image = NSImage(data: bytes) { return ImagePreview(image: image, url: url) }
        let quickLookView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        quickLookView.previewItem = url as NSURL
        quickLookView.shouldCloseWithWindow = false
        return quickLookView
    }
}

/// A file's preview that follows the file. When the file is written over (a new render of a video, an image), the
/// preview is built again, because Quick Look, PDFKit and an image read once keep showing the old content. When the
/// file is deleted, the preview stays as it is.
@MainActor
final class FollowedPreview {
    let view = NSView()
    private(set) var shown: NSView
    /// The file version on screen. It is nil until the daemon pushes the first version, which is the one already shown.
    private var stamp: FileStamp?
    private let version: Watched

    init(url: URL, app: AppModel) {
        shown = NSView()   // until the file is read
        view.pin(shown)
        // A big PDF or video on a slow disk says it is coming, once that has taken a second.
        let wait = LoadingView()
        wait.place(in: view)
        wait.wait(String(localized: "Reading the file…"))
        version = Watched(.file, in: app)
        version.key = url.path
        Task { [weak self] in
            let first = await Preview.view(for: url, app: app)
            await wait.settled()
            wait.show(nil)
            wait.removeFromSuperview()
            self?.show(first)
        }
        track(owner: self) {
            app.latest(FileEvent.self, url.path)?.stamp
        } changed: { [weak self] now in
            guard let self, let now, now != stamp else { return }
            defer { stamp = now }
            if stamp != nil { Task { [weak self] in self?.show(await Preview.view(for: url, app: app)) } }
        }
    }

    private func show(_ next: NSView) {
        let focused = shown.window?.firstResponder === shown
        (shown as? QLPreviewView)?.close()   // otherwise its player keeps playing the old file
        shown.removeFromSuperview()
        shown = next
        view.pin(next)
        if focused { next.window?.makeFirstResponder(next) }
    }
}

/// An image shown as a tab, as Xcode does: centered, and never larger than its own size. ⌘C or Copy Image in its menu
/// puts the image on the pasteboard as the file's own bytes (so a GIF keeps its frames), and also as PNG for apps (and
/// agents) that only read PNG.
@MainActor
final class ImagePreview: NSImageView {
    private let url: URL

    init(image: NSImage, url: URL) {
        self.url = url
        super.init(frame: .zero)
        // One pixel is one point, as in a browser. NSImage would size the image by the file's DPI, so a PNG without
        // 72-dpi metadata would come out huge.
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        self.image = image
        imageScaling = .scaleProportionallyDown
        animates = true
        focusRingType = .none
        // The view's natural size is the image's size, so at the default priority a big image would push the window
        // past the screen.
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

/// Sends links clicked in a PDF through the preview's rules (`PreviewLinks.target`). A repo's PDF can link to an app it
/// ships or to another app's scheme, and PDFKit on its own would open either one.
@MainActor
final class PDFLinks: NSObject, @MainActor PDFViewDelegate {
    private let app: AppModel
    init(app: AppModel) { self.app = app }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { PreviewLinks.open(url, in: app) }
}

/// A PDF view that keeps its own link delegate alive, because PDFView holds its delegate weakly. The delegate is a
/// separate object because PDFView forwards to its delegate what it can't answer, so a view that was its own delegate
/// would ask itself forever.
@MainActor
final class LinkedPDFView: PDFView {
    let links: PDFLinks
    init(app: AppModel) {
        links = PDFLinks(app: app)
        super.init(frame: .zero)
        delegate = links   // without a delegate, PDFKit opens any link in the app for its scheme
    }
    required init?(coder: NSCoder) { fatalError() }
}
