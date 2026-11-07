import AppKit
import Core
import CoreImage
import Virtualization

/// A macOS machine's screen from the Mac's side: what its VZVirtualMachineView shows, read from the IOSurface it draws
/// into, and mouse and key events handed to that view, which sends them to the machine's trackpad and keyboard. Nothing
/// inside the machine is asked, so no permission there; the view needs no window on screen. Points of its 1280 × 800
/// screen, top left first, whatever size the user made its window.
@MainActor
enum Screen {
    /// The session whose turn the screen is, and when that ends (20 s after its last action).
    static var holder: (session: String, until: Date)?

    /// Whose turn it is now, if anyone's.
    static var turn: String? { holder.flatMap { $0.until > Date() ? $0.session : nil } }

    /// `args` as `kelp vm` takes them; `done` with an error or nil once the screen had a moment to follow.
    static func run(_ args: [String], session: String, view: VZVirtualMachineView, done: @escaping (String?) -> Void) {
        let op = args.first ?? ""
        func num(_ i: Int) -> Double? { args.count > i ? Double(args[i]) : nil }
        if op == "screenshot" {
            guard args.count > 1 else { return done("screenshot: a file to write") }
            // A machine just woken or a view just made has no frame for a moment: looked for every 0.2 s, up to 5 s.
            func shoot(_ tries: Int) {
                let error = screenshot(view, to: args[1])
                guard error != nil, tries > 0 else { return done(error) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { shoot(tries - 1) } }   // the main queue
            }
            return shoot(25)
        }
        if session != "-" {   // "-": the user's (Type Password, a terminal outside Kelp): no turn
            if let h = holder, h.session != session, h.until > Date() {
                return done(
                    "The screen is \(h.session)'s now (until 20 s after its last action); try again in a moment.")
            }
            holder = (session, Date().addingTimeInterval(20))
        }
        var events: [NSEvent] = []
        switch op {
        case "click":
            guard let x = num(1), let y = num(2) else { return done("click X Y [--right] [--double]") }
            let right = args.contains("--right")
            events =
                [mouse(.mouseMoved, x, y, view)]
                + (args.contains("--double") ? [1, 2] : [1]).flatMap { n in
                    [
                        mouse(right ? .rightMouseDown : .leftMouseDown, x, y, view, clicks: n),
                        mouse(right ? .rightMouseUp : .leftMouseUp, x, y, view, clicks: n)
                    ]
                }
        case "move":
            guard let x = num(1), let y = num(2) else { return done("move X Y") }
            events = [mouse(.mouseMoved, x, y, view)]
        case "drag":
            guard let x = num(1), let y = num(2), let x2 = num(3), let y2 = num(4) else {
                return done("drag X Y X2 Y2")
            }
            events =
                [mouse(.mouseMoved, x, y, view), mouse(.leftMouseDown, x, y, view)]
                + (1...10).map { i in
                    mouse(.leftMouseDragged, x + (x2 - x) * Double(i) / 10, y + (y2 - y) * Double(i) / 10, view)
                }
                + [mouse(.leftMouseUp, x2, y2, view)]
        case "scroll":
            guard let dy = num(1) else { return done("scroll DY [X Y]") }
            if let x = num(2), let y = num(3) { events.append(mouse(.mouseMoved, x, y, view)) }
            let wheel = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
            if let e = wheel.flatMap(NSEvent.init(cgEvent:)) { events.append(e) }
        case "type":
            let text = args.dropFirst().joined(separator: " ")
            guard let bad = text.first(where: { VMs.usKey($0) == nil }) else {
                events = text.flatMap { typed($0, view) }
                break
            }
            return done("No key for \"\(bad)\" on a US keyboard.")
        case "key":
            guard let e = combo(args.count > 1 ? args[1] : "", view) else {
                return done("key: e.g. cmd+space, return, shift+tab, cmd+shift+t")
            }
            events = e
        default: return done("\(op)? screenshot, click, move, drag, scroll, type, key")
        }
        play(events, on: view) { done(nil) }
    }

    /// Its screen as a PNG of 1280 × 800 points (what clicks take): nil, or what went wrong.
    static func screenshot(_ view: VZVirtualMachineView, to path: String) -> String? {
        func surface(_ l: CALayer) -> IOSurface? {
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                return unsafeDowncast(c as AnyObject, to: IOSurface.self)
            }
            return (l.sublayers ?? []).lazy.compactMap(surface).first
        }
        guard let s = view.layer.flatMap(surface) else {
            return "The machine's screen has nothing to show yet: try again in a second."
        }
        let image = CIImage(ioSurface: s)
        let points = image.transformed(
            by: CGAffineTransform(scaleX: 1280 / image.extent.width, y: 800 / image.extent.height))
        guard let cg = CIContext().createCGImage(points, from: points.extent),
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return "Can't make a PNG of the screen." }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            return "Can't write \(path): \(error.localizedDescription)"
        }
        return nil
    }

    /// A mouse event at screen point (x, y), in the view as it's sized now.
    private static func mouse(
        _ type: NSEvent.EventType, _ x: Double, _ y: Double, _ view: VZVirtualMachineView, clicks: Int = 1
    ) -> NSEvent {
        let b = view.bounds
        let p = view.convert(NSPoint(x: x * b.width / 1280, y: b.height - y * b.height / 800), to: nil)
        let down = [.leftMouseDown, .rightMouseDown, .leftMouseDragged].contains(type)
        return NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: down ? 1 : 0) ?? NSEvent()
    }

    /// Modifiers as their keys (code) and a real left one's flags: the device bit is what the machine's keyboard reads.
    private static let modifiers: [String: (code: UInt16, flags: UInt)] = [
        "shift": (56, 0x20002), "cmd": (55, 0x100008), "command": (55, 0x100008), "alt": (58, 0x80020),
        "option": (58, 0x80020),
        "opt": (58, 0x80020), "ctrl": (59, 0x40001), "control": (59, 0x40001)
    ]

    private static func key(
        _ type: NSEvent.EventType, _ code: UInt16, flags: UInt, _ chars: String, _ view: VZVirtualMachineView
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags | 0x100),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }

    /// Modifier keys down, the key, modifiers up: as a hand presses them.
    private static func press(
        _ code: UInt16, _ mods: [(code: UInt16, flags: UInt)], _ chars: String, _ view: VZVirtualMachineView
    ) -> [NSEvent] {
        var flags: UInt = 0, out: [NSEvent] = []
        for m in mods {
            flags |= m.flags
            out += [key(.flagsChanged, m.code, flags: flags, "", view)].compactMap { $0 }
        }
        out += [key(.keyDown, code, flags: flags, chars, view), key(.keyUp, code, flags: flags, chars, view)].compactMap
        { $0 }
        for m in mods.reversed() {
            flags &= ~m.flags
            out += [key(.flagsChanged, m.code, flags: flags, "", view)].compactMap { $0 }
        }
        return out
    }

    private static func typed(_ c: Character, _ view: VZVirtualMachineView) -> [NSEvent] {
        guard let k = VMs.usKey(c), let shift = modifiers["shift"] else { return [] }
        return press(k.code, k.shift ? [shift] : [], c == "\n" ? "\r" : String(c), view)   // a real Return says \r
    }

    private static func combo(_ text: String, _ view: VZVirtualMachineView) -> [NSEvent]? {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last, let code = VMs.keyCodes[name] else { return nil }
        let mods = parts.dropLast().compactMap { modifiers[$0] }
        guard mods.count == parts.count - 1 else { return nil }
        let chars = name == "return" || name == "enter" ? "\r" : name.count == 1 ? name : ""
        return press(code, mods, chars, view)
    }

    /// One event every 15 ms, to the view itself (a window sends keys only while it's key, and this one may not even be on
    /// screen); after the last, 150 ms for the screen to follow before anyone looks.
    private static func play(_ events: [NSEvent], on view: VZVirtualMachineView, _ done: @escaping () -> Void) {
        func next(_ i: Int) {
            guard i < events.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { done() } }   // the main queue
                return
            }
            let e = events[i]
            switch e.type {
            case .flagsChanged: view.flagsChanged(with: e)
            case .keyDown:   // a Command key goes the way AppKit sends it, as a key equivalent first
                if !(e.modifierFlags.contains(.command) && view.performKeyEquivalent(with: e)) { view.keyDown(with: e) }
            case .keyUp: view.keyUp(with: e)
            case .mouseMoved: view.mouseMoved(with: e)
            case .leftMouseDown: view.mouseDown(with: e)
            case .leftMouseUp: view.mouseUp(with: e)
            case .leftMouseDragged: view.mouseDragged(with: e)
            case .rightMouseDown: view.rightMouseDown(with: e)
            case .rightMouseUp: view.rightMouseUp(with: e)
            case .scrollWheel: view.scrollWheel(with: e)
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { MainActor.assumeIsolated { next(i + 1) } }   // the main queue
        }
        next(0)
    }
}
