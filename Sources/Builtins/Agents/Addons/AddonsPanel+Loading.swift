import AppKit
import Core
import DesignKit
import KelpKit

/// How the panel shows a read that is under way. A quick answer shows nothing. Past `Self.quiet`, a spinner takes the
/// place of the chat's agent logo (on a first read, Loading takes the list's place), and the list is dimmed while it
/// belongs to another chat. The spinner stays for at least `Self.held`, so it doesn't flicker. The answer crossfades in
/// for another chat, and for the same chat a few rows that came or went move the others.
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

    /// Once the read has shown, waits out the rest of `held`, so the spinner doesn't flicker.
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
}

/// The agent's logo in the panel's bar. While the list is read, the system's small spinner stands in its place: the
/// turning ring is the agent's own mark for working, and the panel reading isn't the agent.
@MainActor
final class AddonFace: NSView {
    private let logo = NSImageView()
    private let spinner = NSProgressIndicator.small()

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
            if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            update()
        }
    }

    init() {
        super.init(frame: .zero)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        addSubview(spinner)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.appIcon),
            heightAnchor.constraint(equalToConstant: Metrics.appIcon),
            logo.widthAnchor.constraint(equalToConstant: Metrics.appIcon),
            logo.heightAnchor.constraint(equalTo: logo.widthAnchor),
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        isHidden = logo.image == nil && !busy
        logo.isHidden = busy
        toolTip = busy ? String(localized: "Reading what this chat gets") : nil
    }
}
