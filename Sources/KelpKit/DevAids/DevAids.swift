import AppKit
import Core
import TerminalKit
import WebKit
import WorkbenchKit

/// Developer aids driven by environment variables; inert in normal use.
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
                if sem.wait(timeout: .now() + 1) == .timedOut {   // stuck: record where the main thread is
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

    // A debug build's only, not just uncalled in a release: the input it drives (KELP_TYPE, KELP_CLICK) would let any
    // program start the real app and press its own Allow and Trust.
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
                // KELP_SNAPSHOT_SIZE=1000x760: the window's content size (people's windows are rarely 1440 wide).
                if let size = env["KELP_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
                    size.count == 2
                {
                    main.window?.setContentSize(NSSize(width: size[0], height: size[1]))
                }
                if let uris = env["KELP_SNAPSHOT_OPEN"] {
                    for x in uris.split(separator: "|").map(String.init) {
                        if TabURI.runs(x) { app.workbench.runURI(x) } else { app.workbench.open(x) }
                    }
                }
                // KELP_SNAPSHOT_SHEET=clone|remote[=text]: the clone and SSH sheets (the open panel itself is another process),
                // with text: filled in and started. extension=<GitHub folder>: downloaded, and what it runs asked about.
                // project=<folder>: added as Add Project does (one without git asks first).
                if let spec = env["KELP_SNAPSHOT_SHEET"] {
                    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts[0] == "remote" {
                        RemoteSheet.show(app, start: parts.count > 1 ? parts[1] : nil)
                    } else if parts[0] == "extension", parts.count > 1 {
                        Task { await app.extensions.install(source: parts[1]) }
                    }   // the look before installing
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
                // A run-loop timer rather than the main queue: it also fires while a modal sheet runs.
                let delay = env["KELP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
                // main run loop
                RunLoop.main.add(
                    Timer(timeInterval: delay, repeats: false) { [self] _ in
                        MainActor.assumeIsolated { self.snap(env, to: path) }
                    }, forMode: .common)
            }
        }

        /// KELP_TYPE, KELP_CLICK, KELP_SWITCH: real input events, as a user would make them.
        private func driveInput(_ env: [String: String]) {
            let app = self.app
            if let keys = env["KELP_TYPE"] { typeKeys(keys) }
            // KELP_CLICK="Workspace 2|calc.py": real mouse clicks (via NSApp.sendEvent) on visible text, 0.8 s apart.
            if let targets = env["KELP_CLICK"]?.split(separator: "|") {
                let start = env["KELP_CLICK_DELAY"].flatMap(Double.init) ?? 0.3   // panels that load later need longer
                for (i, t) in targets.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(i) * 0.8) { [self] in
                        click(text: String(t))
                    }
                }
            }
            // KELP_SWITCH="a,b,a": switch workspaces (by name or branch) every 0.7 s, timing each switch.
            if let names = env["KELP_SWITCH"]?.split(separator: ",") {
                for (i, n) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.7) {
                        guard let worktree = app.worktrees.first(where: { $0.displayName == n || $0.branch == n })
                        else {
                            print("SWITCH no \(n)")
                            return
                        }
                        let t0 = Date()
                        app.workbench.show(workspace: worktree.id)
                        self.main.window?.contentView?.layoutSubtreeIfNeeded()
                        self.main.window?.displayIfNeeded()
                        print(String(format: "SWITCH %@ %.0f ms", String(n), Date().timeIntervalSince(t0) * 1000))
                    }
                }
            }
        }

        /// The picture, and what it can't show said as text (sheets, alerts, popovers, panes, web content); then quits.
        private func snap(_ env: [String: String], to path: String) {
            let want = env["KELP_SNAPSHOT_WINDOW"].map {
                ["history": "Session History", "settings": "Settings"][$0] ?? $0
            }
            // The frame view includes the title bar and toolbar.
            // "popover": the card a KELP_HOVER opened (taken after the hover, like the rest).
            let picked =
                env["KELP_SNAPSHOT_WINDOW"] == "settings"
                ? SettingsWindow.window
                : want == "popover"
                    ? NSApp.windows.last { $0.isVisible && $0.className.contains("Popover") }
                    : NSApp.windows.filter(\.isVisible).last { want != nil && $0.title.hasPrefix(want ?? "") }
            guard let window = picked ?? main.window,
                let root = window.contentView?.superview ?? window.contentView
            else { exit(2) }
            // KELP_HOVER="calc.py|Changes": a mouse-entered event for the views showing these texts (hover states can't be
            // reached otherwise without moving the user's pointer). The picture is taken a moment later: a hover card opens
            // after a pause (a commit's waits half a second; KELP_HOVER_WAIT=3 waits longer for what it draws).
            if !Self.hovered, let texts = env["KELP_HOVER"] {
                Self.hovered = true
                for text in texts.split(separator: "|").map(String.init) { Self.hover(text, in: root, window: window) }
                // main run loop
                RunLoop.main.add(
                    Timer(timeInterval: Double(env["KELP_HOVER_WAIT"] ?? "") ?? 1.2, repeats: false) { [self] _ in
                        MainActor.assumeIsolated { self.snap(env, to: path) }
                    }, forMode: .common)
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
                // Its own window: drawn next to the snapshot as "<name>-sheet.png".
                Self.snap(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
            }
            Self.snap(window, to: path)
            // A popover (limits details…) is its own window: next to the snapshot, as "<name>-popover.png".
            // An alert shown on its own (a background app has no window to put the sheet on): "<name>-alert.png".
            for a in NSApp.windows where a.isVisible && a.className.contains("AlertPanel") {
                print(
                    "ALERT",
                    (a.contentView?.allSubviews(of: NSTextField.self) ?? []).map(\.stringValue).filter { !$0.isEmpty })
                Self.snap(a, to: path.replacingOccurrences(of: ".png", with: "-alert.png"))
            }
            for pop in NSApp.windows where pop.isVisible && pop.className.contains("Popover") {
                Self.snap(pop, to: path.replacingOccurrences(of: ".png", with: "-popover.png"))
            }
            // In another language: menu items still in English (their text isn't in Localizable.xcstrings yet).
            if Bundle.main.preferredLocalizations.first != "en" {
                func walk(_ m: NSMenu) {
                    for i in m.items where !i.isSeparatorItem {
                        if let submenu = i.submenu {
                            if submenu !== NSApp.servicesMenu { walk(submenu) }
                            continue
                        }
                        if i.title.range(of: "[А-яЁё]", options: .regularExpression) == nil,
                            i.title.range(of: "[a-z]{3}", options: .regularExpression) != nil
                        {
                            print("UNTRANSLATED", i.title)
                        }
                    }
                }
                NSApp.mainMenu.map(walk)
            }
            for t in main.editors.current?.contents.values.map({ $0 }) ?? []
            where TabURI.scheme(t.uri) == "session" && t.view.window === window {
                guard let term = t.view.allSubviews(of: GhosttyTerminalView.self).first else { continue }
                print(
                    "PANE", TabURI.body(t.uri).prefix(8),
                    term.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            }
            // Web content is drawn out of process and may be missing from the PNG: report what the page really shows
            // (not under a sheet: its run loop may not deliver the script's answer).
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
                    // What the page draws, as "<name>-web<i>.png" (it's out of process, so not in the window's PNG).
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

extension AppDelegate {
    static func menuItem(_ key: String, _ mods: NSEvent.ModifierFlags, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem?
    {
        for i in menu?.items ?? [] {
            if let found = menuItem(key, mods, in: i.submenu) { return found }
            let modifiers = i.keyEquivalentModifierMask.union(
                i.keyEquivalent != i.keyEquivalent.lowercased() ? .shift : [])
            if i.keyEquivalent.lowercased() == key.lowercased(),
                modifiers.intersection([.command, .shift, .option, .control]) == mods
            {
                return i
            }
        }
        return nil
    }

    /// The window as the window server composites it: the macOS 26 materials (sidebar, inspector, glass) and web
    /// content included, which the layer render draws white or not at all. An app may read its own windows without
    /// screen-recording permission. The call is unavailable to Swift since macOS 15, hence dlsym; the layer render
    /// stays as the fallback.
    static func snap(_ w: NSWindow, to path: String) {
        guard !composited(w, to: path), let view = w.contentView?.superview ?? w.contentView else { return }
        render(view, scale: w.backingScaleFactor, to: path)
    }
    private static func composited(_ w: NSWindow, to path: String) -> Bool {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // A sleeping (or locked) display: the window server hands back white, so the layers are drawn instead.
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
            let img = unsafeBitCast(sym, to: Capture.self)(.null, 1 << 3, UInt32(w.windowNumber), 1)?
                .takeRetainedValue(),
            let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// Render the layer tree (what the compositor shows); cacheDisplay misses layer-only content.
    static func render(_ v: NSView, scale: CGFloat, to path: String) {
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
        let size = v.bounds.size
        guard let layer = v.layer,
            let ctx = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        var bg = NSColor.windowBackgroundColor.cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
        ctx.setFillColor(bg)
        ctx.fill(CGRect(origin: .zero, size: size))   // the window frame paints this on screen
        if v.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage(),
            let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    #if DEBUG
        /// A visible label's text or a button's title or tooltip (in a sheet over the window first), or "@x,y": a point in the
        /// window, from its top-left corner (SwiftUI content has no labels). "2:" first double-clicks (a row's rename in place).
        func click(text spec: String) {
            // With KELP_SNAPSHOT_WINDOW=settings the clicks are for that window: "@x,y" from its top left.
            let inSettings = ProcessInfo.processInfo.environment["KELP_SNAPSHOT_WINDOW"] == "settings"
            guard let main = (inSettings ? SettingsWindow.window : nil) ?? main.window else { return }
            let label = spec.hasPrefix("2:") ? String(spec.dropFirst(2)) : spec
            let window =
                main.attachedSheet.flatMap { sheet in
                    let inside = sheet.contentView
                    let named =
                        inside?.allSubviews(of: NSButton.self).contains { $0.title == label } == true
                        || inside?.allSubviews(of: NSTextField.self).contains { $0.stringValue == label } == true
                    return named ? sheet : nil
                } ?? main
            guard let root = window.contentView?.superview else { return }
            // An app in the background: its sheet's first click would only make it key.
            if window !== main { window.makeKey() }
            let point: NSPoint
            var queued = false   // a button tracks the mouse until its mouse-up, which has to be in the queue already
            let double = spec.hasPrefix("2:")
            var text = double ? String(spec.dropFirst(2)) : spec
            // "r@x,y", "r:label": a right click (context menus)
            let right = text.hasPrefix("r@") || text.hasPrefix("r:")
            if right { text = String(text.dropFirst(text.hasPrefix("r:") ? 2 : 1)) }
            if text.hasPrefix("@"), case let xy = text.dropFirst().split(separator: ",").compactMap({ Double($0) }),
                xy.count == 2
            {
                point = NSPoint(x: xy[0], y: window.frame.height - xy[1])
                queued = inSettings   // its list is a table, which waits for its mouse-up
            } else if let field = root.allSubviews(of: NSTextField.self)
                .first(where: { $0.stringValue == text && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor })
            {
                point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            } else if let button = root.allSubviews(of: NSButton.self).first(where: {
                ($0.title == text || $0.toolTip == text) && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor
            }) {
                // Near its left edge: a checkbox stretched over a form has only its box and title there.
                let left = button.bounds.minX + min(10, button.bounds.width / 2)
                point = button.convert(NSPoint(x: left, y: button.bounds.midY), to: nil)
                queued = true
            } else {
                print("CLICK no \(text)")
                return
            }
            // A real click makes what it hits first responder; a window in the background (launched from a shell) doesn't.
            var hit = root.hitTest(root.convert(point, from: nil))
            while let view = hit, !view.acceptsFirstResponder { hit = view.superview }
            if let hit { window.makeFirstResponder(hit) }
            // KELP_MENU with a right click: the menu the view under it gives that click (a table notes its row), built by
            // its delegate, and the item chosen; a synthesized right click shows no menu in an app in the background.
            if right, let title = ProcessInfo.processInfo.environment["KELP_MENU"], let view = hit,
                let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1),
                let menu = view.menu(for: event)
            {
                menu.delegate?.menuNeedsUpdate?(menu)
                let index = menu.items.firstIndex { $0.title == title }
                print("MENU \(title): \(index.map { _ in "chosen" } ?? "not in \(menu.items.map(\.title))")")
                if let index { menu.performActionForItem(at: index) }
                return
            }
            for count in double ? [1, 2] : [1] {
                for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                    guard
                        let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                            pressure: 1)
                    else { continue }
                    // Queued, so a table's mouse-down tracking finds its mouse-up instead of waiting for a real one.
                    if double || queued { NSApp.postEvent(event, atStart: false) } else { NSApp.sendEvent(event) }
                }
            }
            print("CLICK \(text) → workspace \(app.worktree(app.workbench.workspaceId)?.displayName ?? "-")")
        }
    #endif
}

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: t) }
    }
}
