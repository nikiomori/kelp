import AppKit

@MainActor
extension NSWindow {
    /// The window as the window server composites it, or the part of it at `rect` (in the window's coordinates). It
    /// has what the layers can't draw again: a terminal's Metal, web content, the macOS 26 materials. An app may read
    /// its own windows without screen-recording permission. The call is unavailable to Swift since macOS 15, hence
    /// dlsym. Nil on a sleeping (or locked) display, where the window server hands back white.
    public func serverPicture(of rect: NSRect? = nil) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        else { return nil }
        var area = CGRect.null   // the whole window
        if let rect, let top = NSScreen.screens.first?.frame.maxY {   // the window server's y runs down from there
            let onScreen = convertToScreen(rect)
            area = CGRect(x: onScreen.minX, y: top - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        }
        // This window alone (kCGWindowListOptionIncludingWindow), without its frame's shadow.
        return unsafeBitCast(sym, to: Capture.self)(area, 1 << 3, UInt32(windowNumber), 1)?.takeRetainedValue()
    }
}

/// Switching the main window to another group (`Motion.switchOut`…): the old group's picture leaves on top while the
/// new one settles under it.
@MainActor
extension NSView {
    /// What the view shows now, from the window server, for `leave` once what it shows was swapped. Nil when nothing
    /// is to move: under Reduce Motion, in a window that isn't on screen, or when the window server has no picture
    /// (the switch then just shows, as one under Reduce Motion does).
    public func pictureForSwitch() -> CGImage? {
        guard !Motion.reduced, let window, window.isVisible, !isHiddenOrHasHiddenAncestor, bounds.width > 0,
            bounds.height > 0
        else { return nil }
        return Self.takePicture(window, convert(bounds, to: nil))
    }
    /// Where a switch's picture of a window's part comes from: the window server. A test puts a stand-in here, because
    /// the window server keeps no picture of a test's windows (they are see-through there).
    public static var takePicture: @MainActor (NSWindow, NSRect) -> CGImage? = { $0.serverPicture(of: $1) }

    /// The name of the picture `leave` lays over the view.
    public static let leaving = "leaving"

    /// Lays `picture` (`pictureForSwitch`, taken before the swap) over the view, in the same frame as the swap so the
    /// view never shows its empty background, and lets it leave: it shrinks about its middle, blurs and fades over
    /// `Motion.switchOut`, then goes. A picture still leaving from a switch before goes at once, because the new
    /// picture already shows it.
    public func leave(_ picture: CGImage) {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        guard let layer else { return }
        layer.sublayers?.filter { $0.name == Self.leaving }.forEach { $0.removeFromSuperlayer() }
        let ghost = CALayer()
        ghost.name = Self.leaving
        ghost.contents = picture
        ghost.contentsGravity = .resize
        ghost.contentsScale = window?.backingScaleFactor ?? 2
        ghost.frame = layer.bounds
        ghost.zPosition = 1   // over the swapped-in view's layer, wherever AppKit puts it
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = "blur"
        blur?.setValue(0, forKey: kCIInputRadiusKey)
        ghost.filters = blur.map { [$0] }
        let shrink = CATransform3DMakeScale(Motion.switchShrink, Motion.switchShrink, 1)   // a layer's own middle
        let away = CAAnimationGroup()
        away.animations = [
            Self.change("transform", NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: shrink)),
            Self.change("opacity", 1, 0),
            Self.change("filters.blur.inputRadius", 0, Motion.switchBlur)
        ]
        away.duration = Motion.switchOut
        away.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { ghost.removeFromSuperlayer() }   // Core Animation runs it on the main thread
        }
        ghost.opacity = 0   // where it ends, so nothing shows it again before it goes
        ghost.transform = shrink
        layer.addSublayer(ghost)
        ghost.add(away, forKey: Self.leaving)
        CATransaction.commit()
    }
    private static func change(_ keyPath: String, _ from: Any, _ to: Any) -> CABasicAnimation {
        let change = CABasicAnimation(keyPath: keyPath)
        change.fromValue = from
        change.toValue = to
        return change
    }

    /// The name of the spring `settleIn` adds.
    public static let settling = "settle"

    /// Lets the view, just put in place by a switch, settle there after `delay`: from `Motion.switchGrow` about its
    /// middle and `Motion.switchDrop` em lower, to where it stands, on `Motion.switchSpring`. Only its layer moves, so
    /// nothing is laid out again (a terminal keeps its size). Nothing fades: a dark terminal fading in over a light
    /// card read as a grey flash.
    public func settleIn(after delay: TimeInterval) {
        guard !Motion.reduced, window?.isVisible == true, bounds.width > 0 else { return }
        wantsLayer = true   // a view drawn into its parent's layer has none of its own to move
        guard let layer else { return }
        let grow = Motion.switchGrow, drop = Motion.switchDrop * TextSize.of(TextSize.row)
        let lower = CATransform3DMakeTranslation(0, superview?.isFlipped == true ? drop : -drop, 0)
        let spring = Motion.switchSpring("transform")
        spring.fromValue = NSValue(
            caTransform3D: CATransform3DConcat(aboutCentre(CATransform3DMakeScale(grow, grow, 1)), lower))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        spring.fillMode = .backwards   // it waits where it starts
        layer.add(spring, forKey: Self.settling)
    }

    /// Brings a mark that took a new look in (a project's icon after a switch): from `Motion.switchPop` about its
    /// middle and from nothing, on the switch's spring.
    public func popIn() {
        wantsLayer = true
        guard !Motion.reduced, window?.isVisible == true, let layer, bounds.width > 0 else { return }
        let pop = CATransform3DMakeScale(Motion.switchPop, Motion.switchPop, 1)
        let grow = Motion.switchSpring("transform")
        grow.fromValue = NSValue(caTransform3D: aboutCentre(pop))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = Motion.switchSpring("opacity")
        fade.fromValue = 0
        fade.toValue = 1
        layer.add(grow, forKey: "pop")
        layer.add(fade, forKey: "popFade")
    }
}
