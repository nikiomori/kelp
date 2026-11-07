import AppKit
import DesignKit
import QuartzCore

/// What a theme paints on the window's surface, under the panels and, in a theme whose card is clear, the terminals. The
/// layers move on the render server at a few frames a second and stop while Kelp isn't the active app or under Reduce Motion (switched while it's open too).
@MainActor
final class Backdrop: NSView {
    private var ambient: WindowLook.Ambient?
    private let stage = CALayer()
    private var built = NSSize.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(stage)
        for (name, run) in [
            (NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.run(run) }   // queue: .main
            }
        }
        followReduceMotion(#selector(build))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ look: WindowLook) {
        layer?.backgroundColor = look.surface?.cgColor
        guard look.ambient != ambient else { return }
        ambient = look.ambient
        build()
    }

    override func layout() {
        super.layout()
        // Dragging the window's edge, the scene just stretches: built anew at every step, its motes jumped about.
        if inLiveResize { stage.frame = bounds } else if bounds.size != built { build() }
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    @objc private func build() {
        built = bounds.size
        stage.sublayers = nil
        stage.frame = bounds
        guard let ambient, bounds.width > 0 else { return }
        stage.sublayers =
            switch ambient.kind {
            case .aurora: Self.aurora(ambient.colors, in: bounds)
            case .motes: Self.motes(ambient.colors, in: bounds)
            case .grid: Self.grid(ambient.colors, in: bounds)
            }
        run(NSApp.isActive)
    }

    /// Stopped or going again from where it was.
    private func run(_ on: Bool) {
        guard on != (stage.speed != 0) else { return }
        if on {
            let at = stage.timeOffset
            stage.speed = 1
            stage.timeOffset = 0
            stage.beginTime = 0
            stage.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil) - at
        } else {
            stage.timeOffset = stage.convertTime(CACurrentMediaTime(), from: nil)
            stage.speed = 0
        }
    }

    /// Slow, wide lights adding up where they cross.
    private static func aurora(_ colors: [NSColor], in rect: NSRect) -> [CALayer] {
        colors.enumerated().map { index, color in
            let size = max(rect.width, rect.height) * 0.8, light = CAGradientLayer()
            light.type = .radial
            light.colors = [color.withAlphaComponent(0.4).cgColor, color.withAlphaComponent(0).cgColor]
            light.startPoint = CGPoint(x: 0.5, y: 0.5)
            light.endPoint = CGPoint(x: 1, y: 1)
            light.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            light.compositingFilter = "screenBlendMode"
            let places = [(0.2, 0.75), (0.8, 0.8), (0.55, 0.15), (0.1, 0.25), (0.9, 0.35)].map {
                CGPoint(x: rect.width * $0.0, y: rect.height * $0.1)
            }
            let from = index % places.count
            light.position = places[from]
            guard !Motion.reduced else { return light }
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = (0...places.count).map { places[(from + $0) % places.count] }
            drift.duration = 90 + Double(index) * 27
            drift.calculationMode = .cubic
            drift.repeatCount = .infinity
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            light.add(drift, forKey: "drift")
            return light
        }
    }

    /// Specks of light rising through dark water, over the colour of the depth. Each is at its own point of its rise, so
    /// the water is full from the start.
    private static func motes(_ colors: [NSColor], in rect: NSRect) -> [CALayer] {
        let depth = CAGradientLayer()
        depth.frame = rect
        depth.colors = [
            (colors.first ?? .clear).withAlphaComponent(0).cgColor,
            (colors.first ?? .clear).withAlphaComponent(0.22).cgColor
        ]
        let dots = colors.map(softDot)
        return [depth]
            + (0..<Int(rect.width * rect.height / 22_000)).map { index in
                let size = CGFloat.random(in: 3...11), mote = CALayer()
                mote.contents = dots[index % dots.count]
                mote.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                mote.position = CGPoint(x: .random(in: 0...rect.width), y: .random(in: 0...rect.height))
                mote.opacity = .random(in: 0.15...0.5)
                guard !Motion.reduced else { return mote }
                let rise = CABasicAnimation(keyPath: "position.y")
                rise.fromValue = -size
                rise.toValue = rect.height + size
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, mote.opacity, mote.opacity, 0]
                fade.keyTimes = [0, 0.15, 0.7, 1]
                let life = CAAnimationGroup()
                life.animations = [rise, fade]
                life.duration = rect.height / .random(in: 8...22)
                rise.duration = life.duration
                fade.duration = life.duration
                life.timeOffset = .random(in: 0...life.duration)
                life.repeatCount = .infinity
                life.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
                mote.add(life, forKey: "rise")
                return mote
            }
    }

    private static func softDot(_ color: NSColor) -> CGImage? {
        let side = 32, space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(
                colorsSpace: space, colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 1])
        else { return nil }
        let center = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(side) / 2, options: [])
        return ctx.makeImage()
    }

    /// A draughtsman's grid: fine lines, every fifth one stronger.
    private static func grid(_ colors: [NSColor], in rect: NSRect) -> [CALayer] {
        let color = colors.first ?? .white, step: CGFloat = 20
        let tile = NSImage(size: NSSize(width: step * 5, height: step * 5), flipped: false) { bounds in
            for index in 0..<5 {
                color.withAlphaComponent(index == 0 ? 0.16 : 0.07).setFill()
                NSRect(x: CGFloat(index) * step, y: 0, width: 0.5, height: bounds.height).fill(using: .sourceOver)
                NSRect(x: 0, y: CGFloat(index) * step, width: bounds.width, height: 0.5).fill(using: .sourceOver)
            }
            return true
        }
        let layer = CALayer()
        layer.frame = rect
        layer.backgroundColor = NSColor(patternImage: tile).cgColor
        return [layer]
    }
}
