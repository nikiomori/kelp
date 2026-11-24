import AppKit
import Core
import DesignKit
import KelpKit
import WebKit

/// Slides presented with notes: the room sees the slide as large as it goes (on a second screen, a window over all
/// of it; else the tab's own Present), and the speaker gets a window of their own with a timer, the slide, the one
/// before and the one after, and the notes large. ← → and Space step all of them; Esc or closing the window ends it.
/// Each is the tab's page loaded again (`PreviewLinks.last`) with `Presenter.script` or Present on top.
@MainActor
final class Presenter: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    private static var open: [ObjectIdentifier: Presenter] = [:]
    typealias Page = (html: String, baseURL: URL?, scripts: [String])
    private weak var tab: MarkdownTab?
    private var windows: [NSWindow] = []
    private var views: [WKWebView] = []
    /// A rehearsal's length aimed at, in seconds, and the time on each slide so far.
    private var target: Double?, times: [Double] = []

    /// Starts presenting the slides in `tab` with the speaker's window; a rehearsal times each slide against
    /// `rehearsing` (seconds).
    static func start(for tab: MarkdownTab, rehearsing: Double? = nil) {
        guard let last = MarkdownTab.loaded.object(forKey: tab)?.page, open[ObjectIdentifier(tab)] == nil else {
            return
        }
        let presenter = Presenter()
        presenter.tab = tab
        presenter.target = rehearsing
        open[ObjectIdentifier(tab)] = presenter
        let room = NSScreen.screens.first { $0 != tab.view.window?.screen }
        tab.presentingBoards = true
        if let room {
            presenter.add(last, extra: "kelpPresent(true)", frame: room.frame, borderless: true)
        } else {
            tab.runJS("kelpPresent(true)")
        }
        let here = (tab.view.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = NSSize(width: min(1056, here.width - 80), height: min(600, here.height - 80))
        presenter.add(
            last, extra: script(labels: tab.slidesLabels, target: rehearsing),
            frame: NSRect(origin: NSPoint(x: here.midX - size.width / 2, y: here.midY - size.height / 2), size: size),
            borderless: false)
        tab.runJS("window.kelpGo?.(window.kelpAt || 0)")
    }

    static func close(for tab: MarkdownTab) { open[ObjectIdentifier(tab)]?.end() }

    /// The tab's page went to slide `at`: the windows follow.
    static func follow(_ tab: MarkdownTab, at: Int) {
        for web in open[ObjectIdentifier(tab)]?.views ?? [] {
            web.evaluateJavaScript("kelpGo(\(at))", in: nil, in: MarkdownTab.world)
        }
    }

    private func add(
        _ page: Page, extra: String, frame: NSRect, borderless: Bool
    ) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false   // the page's own scripts, as in the tab
        config.userContentController.add(self, contentWorld: MarkdownTab.world, name: "kelpSync")
        for source in page.scripts + [extra] {
            config.userContentController.addUserScript(
                WKUserScript(
                    source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: MarkdownTab.world))
        }
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.loadHTMLString(page.html, baseURL: page.baseURL)
        let window = NSWindow(
            contentRect: frame, styleMask: borderless ? [.borderless] : [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Presenter")
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.delegate = self
        if borderless { window.level = .screenSaver }
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        views.append(web)
    }

    nonisolated func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers script messages on the main thread.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            if kind == "present" { return end() }
            if kind == "rehearsed" { times = (body["times"] as? [NSNumber] ?? []).map(\.doubleValue) }
            guard kind == "slideAt", let at = (body["at"] as? NSNumber)?.intValue else { return }
            for web in views where web != message.webView {
                web.evaluateJavaScript("kelpGo(\(at))", in: nil, in: MarkdownTab.world)
            }
            tab?.runJS("window.kelpAt === \(at) || kelpGo(\(at))")
        }
    }

    nonisolated func windowWillClose(_: Notification) {
        MainActor.assumeIsolated { end() }   // AppKit closes windows on the main thread
    }

    private func end() {
        guard let tab, Self.open[ObjectIdentifier(tab)] === self else { return }
        Self.open[ObjectIdentifier(tab)] = nil
        for window in windows {
            window.delegate = nil
            window.close()
        }
        for web in views { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        if tab.presentingBoards {
            tab.presentingBoards = false
            tab.runJS("kelpPresent(false)")
            tab.onPresentEnded?()
        }
        if let target { tab.rehearsed(times, target: target) }
    }

    /// The speaker's page: the slides' own script has run, and this lays them out for the speaker instead.
    static func script(labels: [String: String], target: Double? = nil) -> String {
        """
        (function () {
          const S = window.kelpSlides; if (!S) return;
          const L = \(MarkdownTab.js(labels)), post = m => webkit.messageHandlers.kelpSync?.postMessage(m);
          const TARGET = \(target.map { String($0) } ?? "null");
          const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls;
            if (text != null) e.textContent = text; return e; };
          document.body.classList.add('kelp-presenter');
          const root = el('div', 'kp-root'), left = el('div', 'kp-left'), right = el('div', 'kp-right');
          const top = el('div', 'kp-top'), clock = el('span', 'kp-clock'), where = el('span', 'kp-where');
          const pause = el('button', 'kp-btn', L.pause), reset = el('button', 'kp-btn', L.reset);
          const now = el('div', 'kp-now'), pair = el('div', 'kp-pair'), was = el('div'), next = el('div');
          const notes = el('div', 'kp-notes');
          top.append(clock, pause, reset, el('span', 'kp-grow'), where);
          pair.append(was, next);
          left.append(top, now, pair);
          right.append(el('div', 'kp-label', L.notes), notes);
          root.append(left, right);
          document.body.append(root);
          let at = 0, started = Date.now(), held = 0, paused = false;
          // A rehearsal: the time on each slide, kept as the speaker moves on and told to Kelp each time.
          const spent = S.map(() => 0), aim = el('span', 'kp-where');
          let since = Date.now();
          const mm = s => Math.floor(s / 60) + ':' + String(Math.floor(s % 60)).padStart(2, '0');
          const keep = () => { if (!paused) spent[at] += (Date.now() - since) / 1000; since = Date.now(); };
          if (TARGET) top.insertBefore(aim, where);
          const tick = () => {
            const s = Math.floor(((paused ? held : held + Date.now() - started)) / 1000);
            clock.textContent = mm(s);
            const here = spent[at] + (paused ? 0 : (Date.now() - since) / 1000);
            if (TARGET) aim.textContent = L.aim + ' ' + mm(TARGET) + ' · ' + L.onIt + ' ' + mm(here);
          };
          pause.onclick = () => {
            if (TARGET) keep();
            if (paused) started = Date.now(); else held += Date.now() - started;
            paused = !paused; pause.textContent = paused ? L.resume : L.pause; tick();
          };
          reset.onclick = () => { held = 0; started = Date.now(); tick(); };
          setInterval(tick, 500); tick();
          const copy = (i, into, label) => {
            into.replaceChildren(...(label ? [el('div', 'kp-label', label)] : []));
            if (S[i]) { const c = S[i].cloneNode(true); c.classList.add('on'); into.append(c); }
          };
          window.kelpGo = i => {
            if (TARGET) { keep(); post({ kind: 'rehearsed', times: spent.slice() }); }
            at = Math.max(0, Math.min(S.length - 1, i));
            where.textContent = L.slide + ' ' + (at + 1) + ' ' + L.of + ' ' + S.length;
            copy(at, now); copy(at - 1, was, L.before); copy(at + 1, next, L.after);
            notes.textContent = S[at].dataset.notes || '';
          };
          addEventListener('keydown', e => {
            const d = { ArrowRight: 1, ArrowDown: 1, PageDown: 1, ' ': 1, ArrowLeft: -1, ArrowUp: -1,
              PageUp: -1 }[e.key];
            if (e.key === 'Escape') {
              if (TARGET) { keep(); post({ kind: 'rehearsed', times: spent.slice() }); }
              post({ kind: 'present' }); return;
            }
            if (!d) return;
            e.preventDefault(); e.stopImmediatePropagation();
            kelpGo(at + d); post({ kind: 'slideAt', at });
          }, true);
          const style = el('style');
          style.textContent = `
            body.kelp-presenter .kelp-deck, body.kelp-presenter .kelp-strip { display: none !important; }
            body.kelp-presenter { margin: 0; background: #171717; color: #f2f2f2; overflow: hidden; }
            .kp-root { position: fixed; inset: 0; display: flex; gap: 16px; padding: 16px;
              font: 13px -apple-system, sans-serif; }
            .kp-left { width: 60%; display: flex; flex-direction: column; gap: 10px; min-width: 0; }
            .kp-right { flex: 1; border-left: 1px solid rgba(255,255,255,.1); padding-left: 16px; overflow: auto; }
            .kp-top { display: flex; align-items: center; gap: 10px; }
            .kp-clock { font-size: 30px; font-weight: 600; font-variant-numeric: tabular-nums; }
            .kp-btn { height: 22px; padding: 0 9px; border: 0; border-radius: 6px; background: rgba(255,255,255,.1);
              color: inherit; font: inherit; font-size: 11px; }
            .kp-grow { flex: 1; } .kp-where, .kp-label { color: rgba(255,255,255,.55); font-size: 11px; }
            .kp-now .slide, .kp-pair .slide { display: block; width: 100% !important; border-radius: 4px; }
            .kp-pair { display: flex; gap: 10px; } .kp-pair > div { flex: 0 0 32%; min-width: 0; }
            .kp-notes { margin-top: 8px; font-size: 21px; line-height: 30px; font-weight: 600;
              white-space: pre-wrap; }`;
          document.head.append(style);
          kelpGo(window.kelpAt || 0);
        })();
        """
    }
}

extension MarkdownTab {
    /// The words of the slides' page and of the speaker's window.
    var slidesLabels: [String: String] {
        [
            "of": String(localized: "of"), "escEnds": canvasLabels.escEnds, "notes": String(localized: "Notes"),
            "slide": String(localized: "Slide"), "saved": String(localized: "Saved"),
            "notesHint": String(localized: "Notes for this slide: only you see them while presenting"),
            "pause": String(localized: "Pause"), "resume": String(localized: "Go On"),
            "reset": String(localized: "Reset Time"), "before": String(localized: "Before"),
            "after": String(localized: "Coming Next"), "keep": String(localized: "Keep"),
            "aim": String(localized: "aiming at"), "onIt": String(localized: "on this slide")
        ]
    }

    /// ⋯'s ways to present slides beyond the bar's Present (as large as the pane): with the speaker's window, or
    /// rehearsed against the clock.
    func presentItems(_ menu: NSMenu) {
        menu.add(String(localized: "Present with Notes")) { [weak self] in
            guard let self else { return }
            Presenter.start(for: self)
        }
        menu.add(String(localized: "Rehearse…")) { [weak self] in self?.rehearse() }
        menu.addItem(.separator())
    }

    func slidesMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        switch kind {
        case "slideMenu":
            guard let line = (body["line"] as? NSNumber)?.intValue, let n = (body["n"] as? NSNumber)?.intValue else {
                break
            }
            let menu = NSMenu(), page = Artifacts.projectPath(url.path)
            menu.add(String(localized: "Other Layouts ×3…")) { [weak self] in
                self?.send(
                    "Other layouts on \(page): write three other layouts of slide \(n) (line \(line)) as slides right "
                        + "after it, each starting with a `<!-- variant -->` line. Same words; "
                        + "leave slide \(n) as it is."
                )
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case "keepSlide":
            guard let line = (body["line"] as? NSNumber)?.intValue,
                let next = SlideVariants.keep(editor.text, line: line)
            else { break }
            editor.apply(text: next, selection: NSRange(location: 0, length: 0))
            Task { _ = await saveFile?() }
        case "slideAt":
            if let at = (body["at"] as? NSNumber)?.intValue { Presenter.follow(self, at: at) }
        case "notes":
            guard let line = (body["line"] as? NSNumber)?.intValue, let text = body["text"] as? String else { break }
            let next = SlideNotes.set(editor.text, line: line, text: text)
            guard next != editor.text else { break }
            editor.apply(text: next, selection: NSRange(location: 0, length: 0))
            Task { _ = await saveFile?() }
        default: return false
        }
        return true
    }
}
