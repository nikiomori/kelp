import AppKit
import Core
import TerminalKit
import WebKit
import WorkbenchKit

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

    #if DEBUG
        /// Draws `window` as "<name>-001.png", "<name>-002.png"… `every` seconds apart, then calls `done`.
        func film(
            _ window: NSWindow, frames: Int, every: Double, path: String, frame: Int = 1,
            then done: @escaping @MainActor () -> Void
        ) {
            guard frame <= frames else { return done() }
            Self.snap(window, to: path.replacingOccurrences(of: ".png", with: String(format: "-%03d.png", frame)))
            RunLoop.main.add(
                Timer(timeInterval: every, repeats: false) { [self] _ in
                    // A Timer on the main run loop fires on the main thread.
                    MainActor.assumeIsolated {
                        film(window, frames: frames, every: every, path: path, frame: frame + 1, then: done)
                    }
                }, forMode: .common)
        }
    #endif

    /// Saves the window as the window server composites it, including the macOS 26 materials (sidebar, inspector,
    /// glass) and web content, which the layer render draws white or not at all. An app may read its own windows
    /// without screen-recording permission. The call is unavailable to Swift since macOS 15, hence dlsym, and the
    /// layer render stays as the fallback.
    static func snap(_ window: NSWindow, to path: String) {
        guard !composited(window, to: path), let view = window.contentView?.superview ?? window.contentView else {
            return
        }
        render(view, scale: window.backingScaleFactor, to: path)
    }
    private static func composited(_ window: NSWindow, to path: String) -> Bool {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // On a sleeping (or locked) display the window server hands back white, so the layers are drawn instead.
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
            let img = unsafeBitCast(sym, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1)?
                .takeRetainedValue(),
            let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// Renders the layer tree (what the compositor shows), because cacheDisplay misses layer-only content.
    static func render(_ view: NSView, scale: CGFloat, to path: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        guard let layer = view.layer,
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
        if view.isFlipped {
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
        /// Clicks a visible label's text or a button's title or tooltip (looking in a sheet over the window first), or
        /// "@x,y", a point in the window from its top-left corner (SwiftUI content has no labels). A "2:" prefix
        /// double-clicks (to rename a row in place).
        func click(text spec: String) {
            // With KELP_SNAPSHOT_WINDOW=settings the clicks go to that window, and "@x,y" counts from its top left.
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
            // In an app in the background, the sheet's first click would only make it key, so make it key first.
            if window !== main { window.makeKey() }
            let point: NSPoint
            var queued = false   // a button tracks the mouse until its mouse-up, which has to be in the queue already
            let double = spec.hasPrefix("2:")
            var text = double ? String(spec.dropFirst(2)) : spec
            // "r@x,y" and "r:label" are right clicks (for context menus)
            let right = text.hasPrefix("r@") || text.hasPrefix("r:")
            if right { text = String(text.dropFirst(text.hasPrefix("r:") ? 2 : 1)) }
            if text.hasPrefix("@"), case let xy = text.dropFirst().split(separator: ",").compactMap({ Double($0) }),
                xy.count == 2
            {
                point = NSPoint(x: xy[0], y: window.frame.height - xy[1])
                queued = inSettings   // the Settings list is a table, which waits for its mouse-up
            } else if let field = root.allSubviews(of: NSTextField.self)
                .first(where: { $0.stringValue == text && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor })
            {
                point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            } else if let button = root.allSubviews(of: NSButton.self).first(where: {
                ($0.title == text || $0.toolTip == text) && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor
            }) {
                // Click near the button's left edge, because a checkbox stretched over a form has only its box and
                // title there.
                let left = button.bounds.minX + min(10, button.bounds.width / 2)
                point = button.convert(NSPoint(x: left, y: button.bounds.midY), to: nil)
                queued = true
            } else {
                print("CLICK no \(text)")
                return
            }
            // A real click makes what it hits the first responder, but a window in the background (launched from a
            // shell) doesn't, so do it here.
            var hit = root.hitTest(root.convert(point, from: nil))
            while let view = hit, !view.acceptsFirstResponder { hit = view.superview }
            if let hit { window.makeFirstResponder(hit) }
            // KELP_MENU with a right click asks the view under the point for its menu (a table notes the row), lets the
            // menu's delegate build it, and chooses the item. A synthesized right click shows no menu in an app in the
            // background.
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
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allSubviews(of: type) }
    }
}
