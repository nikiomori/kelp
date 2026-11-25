import AppKit
import Core
import PDFKit
import WebKit

/// A deck made as a design (`ArtifactCanvas.isDeck`, a 16:9 board a slide) leaves as Markdown slides do: a PDF of a
/// page a board with its words still words, or a PowerPoint of a picture a board with, when `editable`, its words as
/// text boxes over it.
extension MarkdownTab {
    /// Whether this page is a canvas whose boards are slides.
    var isDeck: Bool { page == .canvas && (ArtifactCanvas.read(editor.text)?.isDeck ?? false) }

    /// Each board drawn on its own as `picture(of:)` draws it, in the deck's order.
    private func eachBoard(_ run: (WKWebView, NSSize) async throws -> Void) async throws {
        guard let canvas = ArtifactCanvas.read(editor.text) else { throw CocoaError(.fileReadCorruptFile) }
        let home = url.deletingLastPathComponent()
        for board in canvas.boards {
            let (web, size) = try await Self.drawn(
                home.appendingPathComponent(board.file), width: Double(board.w ?? 1920),
                height: board.h.map(Double.init))
            try await run(web, size)
        }
    }

    func exportBoardsPDF(_ to: URL) async throws {
        let document = PDFDocument()
        try await eachBoard { web, size in
            let config = WKPDFConfiguration()
            config.rect = CGRect(origin: .zero, size: size)
            let data = try await web.pdf(configuration: config)
            if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) }
        }
        guard document.write(to: to) else { throw CocoaError(.fileWriteUnknown) }
    }

    func exportBoardsPowerPoint(_ to: URL, editable: Bool) async throws {
        let (slides, texts) = try await deckSlides(editable: editable)
        try await writePowerPoint(slides, texts: texts, to: to)
    }

    /// A picture of each board 1920 wide, and with `editable` its words (hidden in the picture).
    func deckSlides(editable: Bool) async throws -> ([Data], [[PowerPoint.Text]]) {
        var slides: [Data] = [], texts: [[PowerPoint.Text]] = []
        try await eachBoard { web, size in
            if editable {
                let found = try await web.callAsyncJavaScript(
                    Self.takeWords(
                        of: "document.body", box: "({ left: 0, top: 0, width: innerWidth, height: innerHeight })"),
                    contentWorld: .defaultClient)
                texts.append(Self.texts(found))
            }
            slides.append(try await Self.shot(web, size, scale: 1920 / size.width))
        }
        return (slides, texts)
    }
}
