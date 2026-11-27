import AppKit
import Core
import TerminalKit
import WebKit
import WorkbenchKit

/// Developer aids driven by environment variables. They do nothing in normal use.
///   KELP_SNAPSHOT=/x.png  render the window to a PNG and quit (no screen-recording permission needed)
///   KELP_SNAPSHOT_WORKTREE / _OPEN / _INSPECTOR / _SIZE / _SHEET / _WINDOW / _DELAY / _UPDATE  set the scene first
extension AppDelegate {
    /// KELP_HANG_WATCH=1: logs every main-thread stall over 150 ms (what users feel as freezes).
    static func watchHangs() {
        guard ProcessInfo.processInfo.environment["KELP_HANG_WATCH"] != nil else { return }
        Thread.detachNewThread {
            while true {
                let sent = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1) == .timedOut {   // stuck, so record where the main thread is
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-hang-\(getpid()).txt")
                        .path
                    let sampler = Process()
                    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    sampler.arguments = ["\(getpid())", "1", "-file", out]
                    try? sampler.run()
                    sampler.waitUntilExit()
                    print("HANG-SAMPLE " + out)
                    sem.wait()
                }
                let ms = Date().timeIntervalSince(sent) * 1000
                if ms > 150 { print(String(format: "HANG %.0f ms", ms)) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    // This is compiled only into a debug build, not just left uncalled in a release, because the input it drives
    // (KELP_TYPE, KELP_CLICK) would let any program start the real app and press its own Allow and Trust buttons.
    #if DEBUG
        func snapshotLater(_ path: String) {
            let env = ProcessInfo.processInfo.environment
            if env["KELP_SNAPSHOT_DARK"] == nil { NSApp.appearance = NSAppearance(named: .aqua) }   // cacheDisplay mixes appearances otherwise
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
                main.window?.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
                main.window?.contentView?.layoutSubtreeIfNeeded()
                print("FRAME", main.window?.frame ?? .zero, main.window?.contentView?.superview?.bounds ?? .zero)
                if let panel = env["KELP_SNAPSHOT_INSPECTOR"] { main.showInspector(panel: panel) }
                if let version = env["KELP_SNAPSHOT_UPDATE"] {
                    app.updates.arrived(.init(version: version, notes: nil)) {}
                }
                // KELP_SNAPSHOT_SIZE=1000x760 sets the window's content size (people's windows are rarely 1440 wide).
                if let size = env["KELP_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
                    size.count == 2
                {
                    main.window?.setContentSize(NSSize(width: size[0], height: size[1]))
                }
                if let uris = env["KELP_SNAPSHOT_OPEN"] {
                    for uri in uris.split(separator: "|").map(String.init) {
                        if TabURI.runs(uri) { app.workbench.runURI(uri) } else { app.workbench.open(uri) }
                    }
                }
                // KELP_SNAPSHOT_SHEET=clone|remote[=text] shows the clone or SSH sheet (the open panel itself is
                // another process). With text, the sheet is filled in and started. extension=<GitHub folder> downloads
                // the extension and asks about what it runs. project=<folder> adds the folder as Add Project does (a
                // folder without git asks first).
                if let spec = env["KELP_SNAPSHOT_SHEET"] {
                    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts[0] == "remote" {
                        RemoteSheet.show(app, start: parts.count > 1 ? parts[1] : nil)
                    } else if parts[0] == "extension", parts.count > 1 {
                        Task { await app.extensions.install(source: parts[1]) }
                    }   // shows the question before installing
                    else if parts[0] == "project", parts.count > 1 {
                        app.workbench.addProject(path: parts[1])
                    } else {
                        CloneSheet.show(app, start: parts.count > 1 ? parts[1] : nil)
                    }
                }
                driveInput(env)
                switch env["KELP_SNAPSHOT_WINDOW"] {
                case "history": app.extensions.command("agents.history")?.run([:])
                case "settings":
                    SettingsWindow.show(app, section: env["KELP_SNAPSHOT_SECTION"], group: env["KELP_SNAPSHOT_GROUP"])
                default: break
                }
                // A run-loop timer rather than the main queue, because a timer also fires while a modal sheet runs.
                let delay = env["KELP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
                // The timer is on the main run loop.
                RunLoop.main.add(
                    Timer(timeInterval: delay, repeats: false) { [self] _ in
                        MainActor.assumeIsolated { self.snap(env, to: path) }
                    }, forMode: .common)
            }
        }

        /// Sends the real input events that KELP_TYPE, KELP_CLICK and KELP_SWITCH ask for, as a user would make them.
        private func driveInput(_ env: [String: String]) {
            let app = self.app
            if let keys = env["KELP_TYPE"] { typeKeys(keys) }
            // KELP_COMMAND="git.commitWithAgent|git.commit" runs commands by id, as their menu items run them. They
            // start after KELP_CLICK_DELAY and run KELP_COMMAND_GAP seconds apart (0.8 by default).
            if let ids = env["KELP_COMMAND"]?.split(separator: "|") {
                let start = env["KELP_CLICK_DELAY"].flatMap(Double.init) ?? 0.3
                let gap = env["KELP_COMMAND_GAP"].flatMap(Double.init) ?? 0.8
                for (i, id) in ids.map(String.init).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(i) * gap) {
                        print("COMMAND", id, app.extensions.command(id) == nil ? "none" : "ran")
                        app.extensions.command(id)?.run([:])
                    }
                }
            }
            // KELP_CLICK="Workspace 2|calc.py" sends real mouse clicks (via NSApp.sendEvent) on visible text, 0.8 s
            // apart.
            if let targets = env["KELP_CLICK"]?.split(separator: "|") {
                let start = env["KELP_CLICK_DELAY"].flatMap(Double.init) ?? 0.3   // panels that load later need longer
                for (index, target) in targets.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(index) * 0.8) { [self] in
                        click(text: String(target))
                    }
                }
            }
            // KELP_SWITCH="a,b,a" switches workspaces (by name or branch) every 0.7 s, timing each switch.
            if let names = env["KELP_SWITCH"]?.split(separator: ",") {
                for (index, name) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(index) * 0.7) {
                        guard let worktree = app.worktrees.first(where: { $0.displayName == name || $0.branch == name })
                        else {
                            print("SWITCH no \(name)")
                            return
                        }
                        let t0 = Date()
                        app.workbench.show(workspace: worktree.id)
                        self.main.window?.contentView?.layoutSubtreeIfNeeded()
                        self.main.window?.displayIfNeeded()
                        print(String(format: "SWITCH %@ %.0f ms", String(name), Date().timeIntervalSince(t0) * 1000))
                    }
                }
            }
        }

        /// Takes the picture, prints as text what the picture can't show (sheets, alerts, popovers, panes, web
        /// content), and then quits.
        private func snap(_ env: [String: String], to path: String) {
            let want = env["KELP_SNAPSHOT_WINDOW"].map {
                ["history": "Session History", "settings": "Settings"][$0] ?? $0
            }
            // The frame view includes the title bar and toolbar.
            // "popover" picks the card a KELP_HOVER opened (taken after the hover, like the rest).
            let picked =
                env["KELP_SNAPSHOT_WINDOW"] == "settings"
                ? SettingsWindow.window
                : want == "popover"
                    ? NSApp.windows.last { $0.isVisible && $0.className.contains("Popover") }
                    : NSApp.windows.filter(\.isVisible).last { want != nil && $0.title.hasPrefix(want ?? "") }
            guard let window = picked ?? main.window,
                let root = window.contentView?.superview ?? window.contentView
            else { exit(2) }
            // KELP_HOVER="calc.py|Changes" sends a mouse-entered event to the views showing these texts (hover states
            // can't be reached otherwise without moving the user's pointer). The picture is taken a moment later,
            // because a hover card opens after a pause (a commit's card waits half a second, and KELP_HOVER_WAIT=3
            // waits longer for what it draws).
            if !Self.hovered, let texts = env["KELP_HOVER"] {
                Self.hovered = true
                for text in texts.split(separator: "|").map(String.init) { Self.hover(text, in: root, window: window) }
                // The timer is on the main run loop.
                RunLoop.main.add(
                    Timer(timeInterval: Double(env["KELP_HOVER_WAIT"] ?? "") ?? 1.2, repeats: false) { [self] _ in
                        MainActor.assumeIsolated { self.snap(env, to: path) }
                    }, forMode: .common)
                return
            }
            // KELP_SNAPSHOT_FRAMES=40 first draws the window that many times, KELP_SNAPSHOT_EVERY seconds apart (0.5),
            // as "<name>-001.png"…, the frames of a demo loop; KELP_TYPE's keys play meanwhile. The snapshot follows.
            if !Self.filmed, let count = env["KELP_SNAPSHOT_FRAMES"].flatMap(Int.init) {
                Self.filmed = true
                film(window, frames: count, every: env["KELP_SNAPSHOT_EVERY"].flatMap(Double.init) ?? 0.5, path: path) {
                    self.snap(env, to: path)
                }
                return
            }
            print("WINDOW", window.title, window.frame)
            print(
                "WINDOWS",
                NSApp.windows.filter(\.isVisible).map { "\($0.title.isEmpty ? "-" : $0.title)(\(type(of: $0)))" }
                    .joined(separator: ", "))
            if let sheet = window.attachedSheet {
                print(
                    "SHEET", sheet.className,
                    (sheet.contentView?.allSubviews(of: NSTextField.self) ?? []).map(\.stringValue).filter {
                        !$0.isEmpty
                    })
                // A sheet is its own window, so it is drawn next to the snapshot as "<name>-sheet.png".
                Self.snap(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
            }
            Self.snap(window, to: path)
            // A popover (limits details…) is its own window, drawn next to the snapshot as "<name>-popover.png".
            // An alert shown on its own (a background app has no window to put the sheet on) is "<name>-alert.png".
            for alert in NSApp.windows where alert.isVisible && alert.className.contains("AlertPanel") {
                print(
                    "ALERT",
                    (alert.contentView?.allSubviews(of: NSTextField.self) ?? []).map(\.stringValue).filter {
                        !$0.isEmpty
                    })
                Self.snap(alert, to: path.replacingOccurrences(of: ".png", with: "-alert.png"))
            }
            for pop in NSApp.windows where pop.isVisible && pop.className.contains("Popover") {
                Self.snap(pop, to: path.replacingOccurrences(of: ".png", with: "-popover.png"))
            }
            // In another language, list the menu items still in English (not in Localizable.xcstrings yet).
            if Bundle.main.preferredLocalizations.first != "en" {
                for (i, _) in NSApp.mainMenu?.leaves() ?? []
                where i.title.range(of: "[А-яЁё]", options: .regularExpression) == nil
                    && i.title.range(of: "[a-z]{3}", options: .regularExpression) != nil
                {
                    print("UNTRANSLATED", i.title)
                }
            }
            for t in main.editors.current?.contents.values.map({ $0 }) ?? []
            where TabURI.scheme(t.uri) == "session" && t.view.window === window {
                guard let term = t.view.allSubviews(of: GhosttyTerminalView.self).first else { continue }
                print(
                    "PANE", TabURI.body(t.uri).prefix(8),
                    term.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            }
            // Web content is drawn out of process and may be missing from the PNG, so report what the page really
            // shows. Skip that under a sheet, because the sheet's run loop may not deliver the script's answer.
            let webs = root.allSubviews(of: WKWebView.self)
            guard !webs.isEmpty, window.attachedSheet == nil else {
                finishSnapshot()
                return
            }
            var left = webs.count
            for (i, web) in webs.enumerated() {
                web.evaluateJavaScript(
                    "document.body ? [document.body.innerText.length, document.querySelectorAll('svg').length] : [-1, 0]"
                ) { r, _ in
                    let counts = (r as? [Int]) ?? []
                    let visible = web.window != nil && !web.isHiddenOrHasHiddenAncestor
                    print(
                        "WEB", web.url?.absoluteString ?? "-", "frame", web.frame.size, "visible", visible, "text",
                        counts.first ?? -1, "svg", counts.last ?? 0)
                    // Save what the page draws as "<name>-web<i>.png" (out of process, so not in the window's PNG).
                    guard visible else {
                        left -= 1
                        if left == 0 { self.finishSnapshot() }
                        return
                    }
                    web.takeSnapshot(with: nil) { img, _ in
                        if let tiff = img?.tiffRepresentation,
                            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                        {
                            try? png.write(
                                to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-web\(i).png")))
                        }
                        left -= 1
                        if left == 0 { self.finishSnapshot() }
                    }
                }
            }
        }
    #endif
}
