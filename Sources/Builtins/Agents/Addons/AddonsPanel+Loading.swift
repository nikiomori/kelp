import AppKit
import Core
import DesignKit
import KelpKit

/// How the panel shows a read that is under way. A quick answer shows nothing. Past `Self.quiet`, a ring turns around
/// the logo of the chat's agent (on a first read, Loading takes the list's place), and the list is dimmed while it
/// belongs to another chat. The ring stays for at least `Self.held`, so it doesn't flicker. The answer crossfades in
/// for another chat, and for the same chat it lights up what changed.
extension AddonsPanel {
    static let quiet: Duration = .seconds(1)
    static let held = LoadingView.held

    /// Starts showing the read, but only once it has taken longer than `quiet`. `stale` means what is on screen
    /// belongs to another chat or workspace.
    func beginBusy(stale: Bool) {
        busy?.cancel()
        busy = Task { [weak self] in
            do { try await Task.sleep(for: Self.quiet) } catch { return }
            guard let self else { return }
            busySince = .now
            if addons == nil {
                empty.show(nil)
                loadingView.show(String(localized: "Reading skills and servers…"))
            } else {
                face.busy = true
                if stale { dim(true) }
            }
        }
    }

    /// Once the read has shown, waits out the rest of `held`, so the ring doesn't flicker.
    func settle() async {
        busy?.cancel()
        guard let since = busySince else { return }
        let left = Self.held - Date.now.timeIntervalSince(since)
        guard left > 0 else { return }
        do { try await Task.sleep(for: .seconds(left)) } catch { return }   // a newer read cancelled this one
    }

    func endBusy() {
        busy?.cancel()
        busySince = nil
        face.busy = false
        loadingView.show(nil)
        dim(false)
    }

    /// Fades the list while it still shows another chat's items and this chat's list is being read.
    private func dim(_ on: Bool) {
        let alpha: CGFloat = on ? 0.45 : 1   // still legible, though the list is there to be replaced, not read
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            for view in [table.enclosingScrollView, weight] as [NSView?] { view?.animator().alphaValue = alpha }
        }
    }

    /// Lights up for a moment the rows this answer changed, which are the lines that weren't in the list before.
    func glow(changedFrom before: [AddonLine]) {
        for (row, line) in lines.enumerated() where !before.contains(line) {
            if case .section = line { continue }
            guard let view = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
            let light = EdgeGlow(radius: Metrics.radiusSM, spread: 3, strength: 0.5, hairline: false)
            light.frame = view.bounds.insetBy(dx: Metrics.gap, dy: 1)   // the same frame as the row's hover pill
            light.autoresizingMask = [.width, .height]
            view.addSubview(light)
            light.show(.themeAccent, breathing: false)
            // Once faded, the glow hides itself, and the row view goes away with the next answer's list.
            Task { [weak light] in
                do { try await Task.sleep(for: .seconds(Motion.linger)) } catch { return }
                light?.show(nil, breathing: false)
            }
        }
    }
}

/// The agent's logo in the panel's bar. While the list is read, a working ring turns around it and the logo shrinks
/// inside the ring.
@MainActor
final class AddonFace: NSView {
    private let logo = NSImageView()
    private let ring = StatusMark(size: Metrics.appIcon)
    private var side: NSLayoutConstraint?

    var image: NSImage? {
        get { logo.image }
        set {
            logo.image = newValue
            update()
        }
    }
    var busy = false {
        didSet {
            guard busy != oldValue else { return }
            ring.status = busy ? .working : nil
            update()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.duration(Motion.fast)
                context.allowsImplicitAnimation = true
                layoutSubtreeIfNeeded()
            }
        }
    }

    init() {
        super.init(frame: .zero)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        addSubview(ring)
        translatesAutoresizingMaskIntoConstraints = false
        let side = logo.widthAnchor.constraint(equalToConstant: Metrics.appIcon)
        self.side = side
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.appIcon),
            heightAnchor.constraint(equalToConstant: Metrics.appIcon),
            side, logo.heightAnchor.constraint(equalTo: logo.widthAnchor),
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor), ring.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        isHidden = logo.image == nil && !busy
        side?.constant = busy ? Metrics.iconTiny : Metrics.appIcon
        toolTip = busy ? String(localized: "Reading what this chat gets") : nil
    }
}
