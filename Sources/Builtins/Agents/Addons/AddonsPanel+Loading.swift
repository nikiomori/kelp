import AppKit
import Core
import DesignKit
import KelpKit

/// How the panel shows a read under way: nothing for a quick answer; past `Self.quiet` a turning ring round the chat's
/// agent (a first read: Loading in the list's place), and the list dimmed while it's another chat's; the ring stays
/// `Self.held` so it doesn't flicker. The answer crossfades in for another chat, and lights what changed for the same.
extension AddonsPanel {
    static let quiet: Duration = .milliseconds(150)
    static let held: TimeInterval = 0.4

    /// Past `quiet`, the read shows; `stale`: what's on screen is another chat's or workspace's.
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

    /// Waits out what's left of `held` once the read showed.
    func settle() async {
        busy?.cancel()
        guard let since = busySince else { return }
        let left = Self.held - Date.now.timeIntervalSince(since)
        guard left > 0 else { return }
        do { try await Task.sleep(for: .seconds(left)) } catch { return }   // a newer read: it doesn't show
    }

    func endBusy() {
        busy?.cancel()
        busySince = nil
        face.busy = false
        loadingView.show(nil)
        dim(false)
    }

    /// Another chat's list, faded while this one's is read.
    private func dim(_ on: Bool) {
        let alpha: CGFloat = on ? 0.45 : 1   // still legible: it's there to be replaced, not read
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            for view in [table.enclosingScrollView, weight] as [NSView?] { view?.animator().alphaValue = alpha }
        }
    }

    /// The rows not drawn the same before this answer, lit for a moment: what it changed.
    func glow(changedFrom before: [AddonLine]) {
        for (row, line) in lines.enumerated() where !before.contains(line) {
            if case .section = line { continue }
            guard let view = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
            let light = EdgeGlow(radius: Metrics.radiusSM, spread: 3, strength: 0.5, hairline: false)
            light.frame = view.bounds.insetBy(dx: Metrics.gap, dy: 1)   // the row's hover pill
            light.autoresizingMask = [.width, .height]
            view.addSubview(light)
            light.show(.themeAccent, breathing: false)
            // Faded, it hides itself; the row goes with the next answer's list.
            Task { [weak light] in
                do { try await Task.sleep(for: .seconds(Motion.linger)) } catch { return }
                light?.show(nil, breathing: false)
            }
        }
    }

    /// Over a list that's kept: why it couldn't be read again, and Try Again. nil hides it.
    func failure(_ error: String?) {
        failureLine.stringValue = error.map { String(localized: "Couldn’t refresh: \($0)") } ?? ""
        failureLine.toolTip = error
        if failureBar.isHidden != (error == nil) { failureBar.crossfade() }
        failureBar.isHidden = error == nil
    }

    func makeFailureBar() -> NSView {
        let mark = NSImageView(image: .symbol("exclamationmark.triangle", String(localized: "Couldn’t refresh")))
        mark.symbolConfiguration = .chrome(Metrics.iconSmall)
        mark.contentTintColor = .systemOrange
        failureLine.font = .ui(TextSize.caption)
        failureLine.textColor = .secondaryLabelColor
        failureLine.lineBreakMode = .byTruncatingTail
        failureLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let retry = TextButton(String(localized: "Try Again")) { [weak self] in self?.reload() }
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        failureBar.setViews([mark, failureLine, NSView(), retry], in: .leading)
        failureBar.spacing = Metrics.gap
        failureBar.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        failureBar.isHidden = true
        return failureBar
    }
}

/// The bar's agent: its logo, and while the list is read the working ring round it, the logo shrunk inside.
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
