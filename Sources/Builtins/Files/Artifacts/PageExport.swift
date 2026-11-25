import AppKit
import Core
import DesignKit
import KelpKit
import PDFKit
import UniformTypeIdentifiers
import WebKit
import WorkbenchKit

/// What an agent's page is exported as (⋯ in its bar, the Export command, and `kelp artifact export`): a design's
/// boards as PNG files, slides as a PDF or as a PowerPoint of one picture a slide, the page as one HTML file that
/// holds its pictures, or its folder as a ZIP.
enum PageExport: String, CaseIterable {
    case png, pdf, pptx, html, zip, docx, md

    /// What ⋯ calls it on a page of kind `page`.
    func title(_ page: MarkdownTab.Page) -> String {
        switch self {
        case .png: String(localized: "Boards as PNG…")
        case .pdf: page == .markdown ? String(localized: "Document as PDF…") : String(localized: "Slides as PDF…")
        case .pptx: String(localized: "Slides as PowerPoint…")
        case .html: String(localized: "Page as One HTML…")
        case .zip: String(localized: "Folder as ZIP…")
        case .docx: String(localized: "Document as Word…")
        case .md: String(localized: "Document as Markdown…")
        }
    }

    /// The exports a page of kind `page` has.
    static func formats(for page: MarkdownTab.Page, deck: Bool = false) -> [PageExport] {
        switch page {
        case .canvas: deck ? [.png, .pdf, .pptx, .html, .zip] : [.png, .html, .zip]
        case .slides: [.pdf, .pptx, .html, .zip]
        case .markdown: [.pdf, .docx, .md, .html, .zip]
        default: [.html, .zip]
        }
    }

    /// The file it is saved as; boards go into a folder.
    var type: UTType? {
        switch self {
        case .png: nil
        case .pdf: .pdf
        case .pptx: UTType(filenameExtension: "pptx")
        case .html: .html
        case .zip: .zip
        case .docx: UTType(filenameExtension: "docx")
        case .md: UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

extension ArtifactBar {
    /// ⋯'s Export section, for this page's kind.
    func exportItems(_ menu: NSMenu) {
        menu.addItem(.sectionHeader(title: String(localized: "Export")))
        for format in PageExport.formats(for: markdown.page, deck: markdown.isDeck) {
            menu.add(format.title(markdown.page)) { [weak markdown] in markdown?.chooseExport(format) }
        }
        if markdown.takesRows {   // only a page whose elements take a table's columns
            menu.add(String(localized: "For Each Row of Its Table…")) { [weak markdown] in markdown?.exportEachRow() }
        }
        menu.add(String(localized: "Build in Code…")) { [weak markdown] in markdown?.buildInCode() }
        turnItems(menu)
    }
}

extension MarkdownTab {
    /// The page each tab loaded last and its scripts: for the slides' presenter windows and the one-file export.
    final class LoadedPage {
        let page: (html: String, baseURL: URL?, scripts: [String])
        init(_ page: (html: String, baseURL: URL?, scripts: [String])) { self.page = page }
    }
    static let loaded = NSMapTable<MarkdownTab, LoadedPage>.weakToStrongObjects()

    /// Asks where, then exports the page as `format`.
    func chooseExport(_ format: PageExport) {
        let name = url.deletingLastPathComponent().lastPathComponent
        Task {
            var editable = false
            let to: URL
            if let type = format.type {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [type]
                panel.nameFieldStringValue = name + "." + (type.preferredFilenameExtension ?? format.rawValue)
                let choice = format == .pptx ? Self.powerPointChoice() : nil
                panel.accessoryView = choice
                guard await runSheet(panel) == .OK, let chosen = panel.url else { return }
                if let choice {
                    editable = choice.indexOfSelectedItem == 0
                    Self.editablePowerPoint = editable
                }
                to = chosen
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = String(localized: "Export Here")
                guard await runSheet(panel) == .OK, let chosen = panel.url else { return }
                to = chosen
            }
            await export(format, to: to, editable: editable)
        }
    }

    /// Exports the page as `format` into `to`, and shows it in Finder; a failure is a banner.
    func export(_ format: PageExport, to: URL, editable: Bool = false) async {
        do {
            switch format {
            case .png: try await exportBoards(into: to)
            case .pdf:
                switch page {
                case .canvas: try await exportBoardsPDF(to)
                case .markdown: try await exportDocumentPDF(to)
                default: try await exportSlidesPDF(to)
                }
            case .pptx:
                try await page == .canvas
                    ? exportBoardsPowerPoint(to, editable: editable) : exportSlidesPowerPoint(to, editable: editable)
            case .html: try await exportHTML(to)
            case .zip: try await zip(url.deletingLastPathComponent(), to: to, keepFolder: true)
            case .docx: try exportWord(to)
            case .md: try exportMarkdown(to)
            }
            NSWorkspace.shared.activateFileViewerSelecting([to])
        } catch {
            Banner.show(String(localized: "Couldn’t export: \(error.localizedDescription)"), style: .error)
        }
    }

    /// Each board of the canvas, at its own size (as tall as its content when the board sets no height), as
    /// `<board>.png` in `folder`; with `row`, that row of the tables its elements take columns of.
    func exportBoards(into folder: URL, row: Int? = nil) async throws {
        guard let canvas = ArtifactCanvas.read(editor.text) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let home = url.deletingLastPathComponent()
        for board in canvas.boards {
            let file = home.appendingPathComponent(board.file)
            var html: String?
            if let row, let read = await app.quiet(FilesRead(path: file.path)) {
                var tables: [String: [[String]]] = [:]
                for name in DataRows.files(in: read.text) where !name.contains("/") {
                    let csv = await app.quiet(FilesRead(path: home.appendingPathComponent(name).path))
                    tables[name] = csv.map { DataRows.parse($0.text) }
                }
                html = DataRows.fill(read.text, row: row, tables: tables)
            }
            let w = Double(min(max(board.w ?? 1280, 40), 8000))
            let png = try await Self.picture(of: file, html: html, width: w, height: board.h.map(Double.init))
            let name = (board.file as NSString).lastPathComponent
            try png.write(to: folder.appendingPathComponent((name as NSString).deletingPathExtension + ".png"))
        }
    }

    /// A page file (or `html` in its place) drawn `width` wide without its scripts (as the canvas shows a board), as
    /// tall as `height` or else its content, as PNG at twice the size.
    static func picture(of file: URL, html: String? = nil, width: Double, height: Double?) async throws -> Data {
        let (web, size) = try await drawn(file, html: html, width: width, height: height)
        return try await shot(web, size)
    }

    /// A page file (or `html` in its place) loaded in a web view of its own `width` wide without its scripts, sized
    /// `height` tall or else to its content.
    static func drawn(_ file: URL, html: String? = nil, width: Double, height: Double?) async throws -> (
        WKWebView, NSSize
    ) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Short at first, so a page shorter than the view measures as itself.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height ?? 40), configuration: config)
        let loaded = PageLoaded()
        web.navigationDelegate = loaded
        if let html {
            web.loadHTMLString(html, baseURL: file)
        } else {
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent().deletingLastPathComponent())
        }
        await loaded.wait()
        // Measured in Kelp's own script world: the page's scripts stay off.
        let tall =
            try await web.callAsyncJavaScript(
                "return document.documentElement.scrollHeight", contentWorld: .defaultClient) as? Double
        let size = NSSize(width: width, height: min(max(height ?? tall ?? 800, 40), 8000))
        web.setFrameSize(size)
        return (web, size)
    }

    /// What `web` shows, `size` large, as PNG at `scale` times the size.
    static func shot(_ web: WKWebView, _ size: NSSize, scale: Double = 2) async throws -> Data {
        let shot = WKSnapshotConfiguration()
        shot.snapshotWidth = NSNumber(value: size.width)
        let image = try await web.takeSnapshot(configuration: shot)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard let png = Self.png(image, width: w, height: h) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    static func png(_ image: NSImage, width: Int, height: Int) -> Data? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Where each slide is in the page, shown in turn: `run` gets its number and its box, and the page goes back to
    /// the slide it was on.
    private func eachSlide(_ run: (Int, CGRect) async throws -> Void) async throws {
        // A page just opened lays its slides out once it has loaded: wait for that, five seconds at most.
        let count = try await web.callAsyncJavaScript(
            "for (let i = 0; i < 100 && !window.kelpSlides; i++) await new Promise(r => setTimeout(r, 50));"
                + "return window.kelpSlides?.length ?? 0", contentWorld: Self.world)
        let was = try await web.evaluateJavaScript("window.kelpAt ?? 0", contentWorld: Self.world) as? Int ?? 0
        defer { runJS("kelpGo(\(was))") }
        for i in 0..<((count as? Int) ?? 0) {
            let box = try await web.callAsyncJavaScript(
                """
                kelpGo(i); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                const b = kelpSlides[i].getBoundingClientRect(); return [b.x, b.y, b.width, b.height]
                """, arguments: ["i": i], contentWorld: Self.world)
            guard let b = box as? [Double], b.count == 4 else { continue }
            try await run(i, CGRect(x: b[0], y: b[1], width: b[2], height: b[3]))
        }
    }

    /// The slides as a PDF, a page a slide, their words still words.
    private func exportSlidesPDF(_ to: URL) async throws {
        let document = PDFDocument()
        try await eachSlide { _, box in
            let config = WKPDFConfiguration()
            config.rect = box
            let data = try await web.pdf(configuration: config)
            if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) }
        }
        guard document.write(to: to) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The slides as a PowerPoint of one picture a slide, 1920 wide; `editable`, their words as text boxes over a
    /// picture taken without them.
    private func exportSlidesPowerPoint(_ to: URL, editable: Bool) async throws {
        var slides: [Data] = [], texts: [[PowerPoint.Text]] = []
        try await eachSlide { i, box in
            if editable { texts.append(try await slideTexts(i)) }
            let shot = WKSnapshotConfiguration()
            shot.rect = box
            shot.snapshotWidth = NSNumber(value: 1920 / Double(view.window?.backingScaleFactor ?? 2))
            let image = try await web.takeSnapshot(configuration: shot)
            if editable { _ = try await web.callAsyncJavaScript(Self.showWords, contentWorld: Self.world) }
            if let png = Self.png(image, width: 1920, height: 1080) { slides.append(png) }
        }
        try await writePowerPoint(slides, texts: texts, to: to)
    }

    /// A PowerPoint of `slides` (PNG pictures) with `texts` over them, at `to`.
    func writePowerPoint(_ slides: [Data], texts: [[PowerPoint.Text]], to: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PowerPoint.write(slides, texts: texts, into: folder)
        try await zip(folder, to: to, keepFolder: false)
        do { try FileManager.default.removeItem(at: folder) } catch { return }   // temporary: the system clears it
    }

    /// The page as one file: its pictures and styles from its folder put inside it; slides keep their own script.
    private func exportHTML(_ to: URL) async throws {
        guard let page = Self.loaded.object(forKey: self)?.page else { throw CocoaError(.fileReadUnknown) }
        var html = PageInline.inline(page.html, folder: url.deletingLastPathComponent())
        if self.page == .slides {
            let shim = "window.webkit = window.webkit || { messageHandlers: {} };"
            html += "<script>\(shim)\(SlidesPage.script(labels: slidesLabels))</script>"
        }
        try html.write(to: to, atomically: true, encoding: .utf8)
    }

    /// `folder` as a ZIP at `to`: with the folder itself in it, or (a PowerPoint) only what it holds.
    private func zip(_ folder: URL, to: URL, keepFolder: Bool) async throws {
        do { try FileManager.default.removeItem(at: to) } catch CocoaError.fileNoSuchFile {}   // ditto won't replace
        let argv =
            ["/usr/bin/ditto", "-c", "-k", "--norsrc"] + (keepFolder ? ["--keepParent"] : []) + [folder.path, to.path]
        let done = await Shell.exec(app, argv)
        guard done.code == 0 else { throw RPCError.internalError(done.stderr) }
    }
}

/// Waits for a web view's page to finish loading (or fail).
@MainActor
final class PageLoaded: NSObject, WKNavigationDelegate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async {
        if done { return }
        await withCheckedContinuation { waiting = $0 }
    }
    private func finish() {
        done = true
        waiting?.resume()
        waiting = nil
    }
    nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        MainActor.assumeIsolated { finish() }   // WebKit calls its delegate on the main thread
    }
    nonisolated func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) {
        MainActor.assumeIsolated { finish() }   // WebKit calls its delegate on the main thread
    }
}

extension Builtins {
    /// The agent's page in the focused tab, else nil.
    static func artifactPage(_ app: AppModel) -> MarkdownTab? {
        (app.workbench.focusedContent as? FileTab)?.markdown.flatMap { $0.artifactBar == nil ? nil : $0 }
    }

    /// Export Page…: with `path`, `format` and `to` (`kelp artifact export`), that page is opened beside if it isn't,
    /// and written there; with none, the focused page's exports are offered.
    static func exportPage(_ app: AppModel, _ args: [String: JSONValue]) {
        let video = args["format"]?.string.flatMap(MotionExport.Format.init(rawValue:))
        guard let path = args["path"]?.string, let to = args["to"]?.string,
            let format = video == nil ? args["format"]?.string.flatMap(PageExport.init(rawValue:)) : .zip
        else {
            guard let tab = artifactPage(app) else { return NSSound.beep() }
            let menu = NSMenu()
            for format in PageExport.formats(for: tab.page, deck: tab.isDeck) {
                menu.add(format.title(tab.page)) { tab.chooseExport(format) }
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        Task {
            if loadedTab(path) == nil { app.workbench.open(TabURI.file(path)) }
            let found: MarkdownTab?
            if let open = loadedTab(path) {
                found = open
            } else {
                found = await withCheckedContinuation { go in
                    waiting.append((path, go))
                    // A page that never draws (no window to open it in) gives up once, after 15 seconds.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { pageDrawn(nil, path: path) }
                }
            }
            guard let tab = found else {
                return Banner.show(String(localized: "Couldn’t open the page to export it."), style: .error)
            }
            if let video { return tab.exportVideo(to: URL(fileURLWithPath: to), format: video) }
            if format == .png {
                do { try FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true) } catch {
                    return Banner.show(error.localizedDescription, style: .error)
                }
            }
            await tab.export(format, to: URL(fileURLWithPath: to))
        }
    }

    /// Exports waiting for their page's tab to draw it (`pageDrawn`).
    private static var waiting: [(path: String, go: CheckedContinuation<MarkdownTab?, Never>)] = []

    /// `tab` drew the page at `path` (its own when nil), or gave up on it (nil): an export waiting for it goes on.
    static func pageDrawn(_ tab: MarkdownTab?, path: String? = nil) {
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        guard let page = path ?? tab?.url.path else { return }
        for (i, wait) in waiting.enumerated().reversed() where real(wait.path) == real(page) {
            waiting.remove(at: i)
            wait.go.resume(returning: tab)
        }
    }

    /// The open tab showing the page at `path`, once it has drawn it.
    private static func loadedTab(_ path: String) -> MarkdownTab? {
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }   // /tmp is /private/tmp
        return MarkdownTab.loaded.keyEnumerator().allObjects.compactMap { $0 as? MarkdownTab }.first {
            real($0.url.path) == real(path)
        }
    }
}

extension MarkdownTab {
    /// Leaves a video's check where `kelp artifact export` waits for it.
    func leaveCheck(_ verdict: MotionVerify, for video: URL) {
        let file = Artifacts.exportCheck(for: video.path)
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(verdict).write(to: file)
        } catch { return }   // no one waits for it but an agent's export, which says so when time runs out
    }
}
