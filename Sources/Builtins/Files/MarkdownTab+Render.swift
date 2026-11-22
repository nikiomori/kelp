import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

/// Builds the preview's page off the main thread, for whatever the file is (a doc, slides, a review, a canvas, HTML).
/// While a plain document is being typed, only its body is replaced in place.
extension MarkdownTab {
    /// What the preview shows, decided from the file's path.
    enum Page {
        case markdown
        /// An agent's slides: the Markdown cut into 16:9 slides.
        case slides
        /// A review an agent wrote. The user answers its page rather than just reading it (`ReviewPage`).
        case review
        /// An agent's HTML page. The preview shows the file itself.
        case html
        /// A design's canvas.json. The preview shows its boards, drawn by Kelp (`CanvasPage`).
        case canvas
        /// An agent's motion page (motion.html): its CSS animations on one timeline that Kelp plays (`MotionPage`).
        case motion

        @MainActor init(_ url: URL) {
            if url.lastPathComponent == Artifacts.Kind.design.file && ArtifactBar.isPage(url.path) {
                self = .canvas
            } else if url.lastPathComponent == Artifacts.Kind.motion.file && ArtifactBar.isPage(url.path) {
                self = .motion
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
    /// Renders the preview. The page is built off the main thread, because a document can be long or inline mermaid's
    /// 5.5 MB script. It isn't built at all while only the source shows.
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
            var page: (background: String, text: String)?, accent = ""
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                let colors = CodeEditor.page
                page = (colors.background.hexString, colors.text.hexString)
                accent = NSColor.controlAccentColor.hexString
            }
            // Kelp's own page takes the Mac's accent, as the window around it does (Graphite is grey there too).
            let ownAccent =
                "document.documentElement.style.setProperty('--k-accent', '\(accent)');" + PageSymbols.script()
            let kind = self.page, sendTo = pageAuthor?.title, labels = canvasLabels, columnLabels = markColumnLabels
            let motion = kind == .motion ? motionScripts(at: motionStudio.at) : []
            let animatedNote = String(localized: "Its animation moves it: change that instead")
            let editLabels = canvasEditLabels, again = canvasModeScripts, chrome = canvasChromeLabels
            let themes =
                CanvasPage.Themes(rawValue: UserDefaults.standard.string(forKey: CanvasPage.themesKey) ?? "")
                ?? (dark ? .dark : .light)
            let canvasView = CanvasPage.View(
                themes: isDashboard ? (dark ? .dark : .light) : themes, writer: canvasWriter, dashboard: isDashboard)
            // An agent's Markdown page (a doc, slides) takes marks, and a doc shows what the agent's last turn changed.
            let agents = artifactBar != nil && (kind == .markdown || kind == .slides)
            let markLabels = pageMarkLabels,
                slideLabels = ["of": String(localized: "of"), "escEnds": canvasLabels.escEnds]
            let turn = shown == nil && kind == .markdown ? baseline : nil
            let noSource = String(localized: "Where it came from isn't said: ask its agent for a data-source.")
            if turn == nil, agents { onChanges?(0) }
            let (html, scripts, swap) = await Task.detached { [page] () -> (String, [String], Swap?) in
                if kind == .html { return (text, [], nil) }
                if kind == .canvas || kind == .motion {
                    let root = Self.projectRoot(of: base.path)
                    let snapshot = shown.flatMap(CanvasSnapshot.read) ?? CanvasSnapshot.live(json: text, folder: base)
                    let built =
                        kind == .motion
                        ? MotionPage.build(text, folder: base, root: root)
                        : CanvasPage.build(snapshot, folder: base, root: root, view: canvasView)
                    let around = CanvasChrome.source(
                        themes: kind == .motion ? "" : themes.rawValue, labels: chrome,
                        floats: !canvasView.dashboard && kind != .motion)
                    let column = MarkColumn.source(marks: built.marks, labels: columnLabels)
                    let edit = CanvasEdit.source(tweaks: built.tweaks, before: built.before, labels: labels)
                    let byHand = CanvasEditMode.source(tokens: built.tokens, labels: editLabels)
                    let handles = CanvasHandles.source(animated: animatedNote)
                    let dash = canvasView.dashboard ? [DashboardPage.source(noSource: noSource)] : []
                    return (
                        built.html,
                        [ownAccent, CanvasScript.source(issues: built.issues), around, column, edit, byHand, handles]
                            + dash + motion
                            + again,
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
                let marks = ArtifactMarks.read(Artifacts.small(base.appendingPathComponent(ArtifactMarks.file).path))
                html += PageMarks.style
                scripts += [
                    ownAccent, CanvasChrome.source(themes: "", labels: chrome, floats: false),
                    MarkColumn.source(marks: marks, labels: columnLabels), PageMarks.source(labels: markLabels)
                ]
                if let turn { scripts.append(PageMarks.changes(Artifacts.changedLines(from: turn, to: text))) }
                return (html, scripts + again, nil)
            }.value
            guard !Task.isCancelled else { return }
            if let swap, let swappable, swap.samePage(as: swappable), !web.isLoading, await replace(swap) { return }
            // Keeps the reader's place and the slide shown across re-renders. Both values are numbers, so the async
            // call can't trap on nil.
            let was =
                (try? await web.evaluateJavaScript("[window.scrollY, window.kelpAt ?? 0]", contentWorld: Self.world))
                as? [Double] ?? [0, 0]
            let scrollY = was.first ?? 0, slide = Int(was.last ?? 0)
            guard !Task.isCancelled else { return }
            // In Split, the preview goes to the block being edited; otherwise it goes back to where it was.
            let place =
                currentMode == "split" && (kind == .markdown || kind == .slides)
                ? "kelpToLine(\(editor.cursor?.line ?? 1))"
                : kind == .slides ? "kelpGo(\(slide))" : "window.scrollTo(0, \(scrollY))"
            // A canvas is Kelp's own page, so its scripts run; its boards sit in frames sandboxed without scripts
            // (`CanvasPage`).
            links.load(
                html, baseURL: base, scripts: scripts + [place], world: Self.world,
                pageScripts: kind == .canvas || kind == .motion,
                in: web)
            swappable = swap
        }
    }

    /// The rendered page of a plain document. It holds the page's body and what the page is made of: the document's
    /// folder, the appearance, the colours, and the scripts the body needs.
    struct Swap: Sendable {
        let folder: String, dark: Bool, colors: String?, mermaid: Bool, math: Bool
        let body: String
        func samePage(as other: Swap) -> Bool {
            (folder, dark, colors, mermaid, math) == (other.folder, other.dark, other.colors, other.mermaid, other.math)
        }
    }

    /// Replaces the body of the page on screen with the body in `swap`, and draws its diagrams and formulas again.
    /// Loading a new page at each pause in typing read the mermaid and KaTeX scripts again and lost the reader's place.
    /// Returns false when the page has no body to replace.
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
            return false   // so the caller loads a new page
        }
    }
}
