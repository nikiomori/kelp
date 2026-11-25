import AppKit
import Core
import Markdown
import WebKit

/// A document leaves as people pass documents on: a PDF in A4 pages as it prints, its Markdown as it is, or a Word file
/// (the system's own writer: headings, lists, tables and links keep their look; code is plain text).
extension MarkdownTab {
    /// The page as the preview shows it, in A4 pages, saved at `to` without a panel.
    func exportDocumentPDF(_ to: URL) async throws {
        guard let window = view.window else { throw CocoaError(.fileWriteUnknown) }
        if web.isHidden { selectMode(2) }   // the page as the preview shows it, not the Markdown
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = to
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        let done = PrintDone()
        op.runModal(
            for: window, delegate: done, didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil)
        guard await done.wait() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The document's Markdown, as the file holds it.
    func exportMarkdown(_ to: URL) throws {
        try editor.text.write(to: to, atomically: true, encoding: .utf8)
    }

    /// The document as a Word file, from the page the Markdown makes (light, whatever the window's look).
    func exportWord(_ to: URL) throws {
        try Self.word(editor.text, baseURL: url.deletingLastPathComponent()).write(to: to)
    }

    static func word(_ markdown: String, baseURL: URL?) throws -> Data {
        let html = MarkdownHTML.page(body: MarkdownHTML.render(markdown), baseURL: baseURL, dark: false)
        let text = try NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil)
        return try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}

/// Waits for a print operation run as a sheet to end.
@MainActor
final class PrintDone: NSObject {
    private var waiting: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiting = $0 }
    }
    /// AppKit calls it on the thread the saving ran on, not always the main one.
    @objc nonisolated func printOperationDidRun(
        _: NSPrintOperation, success: Bool, contextInfo _: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in finish(success) }
    }
    private func finish(_ success: Bool) {
        result = success
        waiting?.resume(returning: success)
        waiting = nil
    }
}
