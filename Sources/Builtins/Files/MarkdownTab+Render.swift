import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

/// The preview's page: built off the main thread for what the file is (a doc, slides, a review, a canvas, HTML), and
/// a plain document's body replaced in place while it's typed.
extension MarkdownTab {
    /// What the preview shows, from the file's path.
    enum Page {
        case markdown
        /// An agent's slides: the Markdown cut into 16:9 slides.
        case slides
        /// A review an agent wrote: its page is answered, not read (`ReviewPage`).
        case review
        /// An agent's page of HTML: the preview is the file itself.
        case html
        /// A design's canvas.json: the preview is its boards, drawn by Kelp (`CanvasPage`).
        case canvas

        @MainActor init(_ url: URL) {
            if url.lastPathComponent == Artifacts.Kind.design.file && ArtifactBar.isPage(url.path) {
                self = .canvas
            } else if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                self = .html
            } else if Review.isReview(url.path) {
                self = .review
            } else if url.lastPathComponent == Artifacts.Kind.slides.file && ArtifactBar.isPage(url.path) {
                self = .slides
            } else {
                self = .markdown
            }
        }
    }
    /// The page is built off the main thread (a long document, or mermaid's 5.5 MB script inlined), and not at all
    /// while only the source shows.
    func rerender(after delay: Duration = .zero) {
        renderTask?.cancel()
        guard !web.isHidden else {
            dirty = true
            return
        }
        dirty = false
        renderTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let text = shownVersion ?? editor.text, base = url.deletingLastPathComponent(), shown = shownVersion
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var page: (background: String, text: String)?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                let colors = CodeEditor.page
                page = (colors.background.hexString, colors.text.hexString)
            }
            let kind = self.page, sendTo = pageAuthor?.title, labels = canvasLabels
            let editLabels = canvasEditLabels, again = canvasModeScripts, chrome = canvasChromeLabels
            let themes =
                CanvasPage.Themes(rawValue: UserDefaults.standard.string(forKey: CanvasPage.themesKey) ?? "")
                ?? (dark ? .dark : .light)
            let canvasView = CanvasPage.View(
                themes: isDashboard ? (dark ? .dark : .light) : themes, writer: canvasWriter, dashboard: isDashboard)
            // An agent's Markdown page (a doc, slides) takes marks, and a doc shows what its agent's last turn changed.
            let agents = artifactBar != nil && (kind == .markdown || kind == .slides)
            let markLabels = pageMarkLabels,
                slideLabels = ["of": String(localized: "of"), "escEnds": canvasLabels.escEnds]
            let turn = shown == nil && kind == .markdown ? baseline : nil
            let noSource = String(localized: "Where it came from isn't said: ask its agent for a data-source.")
            if turn == nil, agents { onChanges?(0) }
            let (html, scripts, swap) = await Task.detached { [page] () -> (String, [String], Swap?) in
                if kind == .html { return (text, [], nil) }
                if kind == .canvas {
                    let snapshot = shown.flatMap(CanvasSnapshot.read) ?? CanvasSnapshot.live(json: text, folder: base)
                    let built = CanvasPage.build(
                        snapshot, folder: base, root: Self.projectRoot(of: base.path), view: canvasView)
                    let around = CanvasChrome.source(
                        themes: themes.rawValue, labels: chrome, floats: !canvasView.dashboard)
                    let edit = CanvasEdit.source(marks: built.marks, tweaks: built.tweaks, labels: labels)
                    let byHand = CanvasEditMode.source(tokens: built.tokens, labels: editLabels)
                    let dash = canvasView.dashboard ? [DashboardPage.source(noSource: noSource)] : []
                    return (
                        built.html, [CanvasScript.source(issues: built.issues), around, edit, byHand] + dash + again,
                        nil
                    )
                }
                if kind == .review {
                    let body = ReviewPage.body(Review(text), sendTo: sendTo)
                    return (
                        MarkdownHTML.page(body: body, baseURL: base, dark: dark, page: page) + ReviewPage.style,
                        [ReviewPage.script], nil
                    )
                }
                let body = MarkdownHTML.render(text, marking: true)
                var html = MarkdownHTML.page(body: body, baseURL: base, dark: dark, page: page)
                let mermaid = MarkdownHTML.mermaid(for: text, dark: dark), math = MarkdownHTML.math(for: body)
                var scripts = [mermaid, math, MarkdownHTML.scrollSync].compactMap { $0 }
                if kind == .slides {
                    let system = DesignSystem.dir(root: Self.projectRoot(of: base.path)).appendingPathComponent(
                        "tokens.json")
                    let tokens = Artifacts.small(system.path, limit: 1 << 20).map {
                        String(decoding: $0, as: UTF8.self)
                    }
                    html += SlidesPage.style + SlidesPage.tokens(tokens ?? "")
                    scripts.append(SlidesPage.script(labels: slideLabels))
                }
                guard agents else {
                    let swap = Swap(
                        folder: base.path, dark: dark, colors: page.map { $0.background + $0.text },
                        mermaid: mermaid != nil, math: math != nil, body: body)
                    return (html, scripts, kind == .markdown ? swap : nil)
                }
                let marks = CanvasMark.read(Artifacts.small(base.appendingPathComponent(CanvasMark.file).path))
                html += PageMarks.style
                scripts += [
                    CanvasChrome.source(themes: "", labels: chrome, floats: false),
                    PageMarks.source(marks: marks, labels: markLabels)
                ]
                if let turn { scripts.append(PageMarks.changes(Artifacts.changedLines(from: turn, to: text))) }
                return (html, scripts + again, nil)
            }.value
            guard !Task.isCancelled else { return }
            if let swap, let swappable, swap.samePage(as: swappable), !web.isLoading, await replace(swap) { return }
            // Keep the reader's place across re-renders, and the slide shown (numbers both, so the async call can't trap
            // on nil).
            let was =
                (try? await web.evaluateJavaScript("[window.scrollY, window.kelpAt ?? 0]", contentWorld: Self.world))
                as? [Double] ?? [0, 0]
            let scrollY = was.first ?? 0, slide = Int(was.last ?? 0)
            guard !Task.isCancelled else { return }
            // In Split, on the block being edited; the place it had otherwise.
            let place =
                currentMode == "split" && (kind == .markdown || kind == .slides)
                ? "kelpToLine(\(editor.cursor?.line ?? 1))"
                : kind == .slides ? "kelpGo(\(slide))" : "window.scrollTo(0, \(scrollY))"
            // A canvas is Kelp's own page: its boards sit in frames sandboxed without scripts (`CanvasPage`).
            links.load(
                html, baseURL: base, scripts: scripts + [place], world: Self.world, pageScripts: kind == .canvas,
                in: web)
            swappable = swap
        }
    }

    /// A plain document's page: what it's made of (its folder, appearance, colours, and the scripts its body needs), and
    /// its body.
    struct Swap: Sendable {
        let folder: String, dark: Bool, colors: String?, mermaid: Bool, math: Bool
        let body: String
        func samePage(as other: Swap) -> Bool {
            (folder, dark, colors, mermaid, math) == (other.folder, other.dark, other.colors, other.mermaid, other.math)
        }
    }

    /// The page shown takes `swap`'s body in place, its diagrams and formulas drawn again: a new page for each pause in the
    /// typing read mermaid's and KaTeX's scripts again and lost the place. False when the page has no body to replace.
    func replace(_ swap: Swap) async -> Bool {
        let place = currentMode == "split" ? "kelpToLine(\(editor.cursor?.line ?? 1));" : ""
        let js = """
            (() => {
              const body = document.querySelector('article.markdown-body');
              if (!body) return false;
              body.innerHTML = \(Self.js(swap.body));
              \(swap.mermaid ? MarkdownHTML.mermaidRun : "")
              \(swap.math ? MarkdownHTML.mathRun : "")
              \(place)
              return true;
            })()
            """
        do { return try await web.evaluateJavaScript(js, contentWorld: Self.world) as? Bool == true } catch {
            return false   // a new page, then
        }
    }
}
