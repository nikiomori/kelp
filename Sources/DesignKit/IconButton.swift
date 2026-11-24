import AppKit

/// A button that is an icon (and maybe a count): a 13 pt medium symbol in secondary grey on a 22 pt square. Under the
/// pointer the square fades to grey; pressed, it darkens; and a click dips it and springs it back (`PointerButton`).
/// This is the one icon button used in bars: a panel's header, a tab's toolbar, the sidebar. It keeps its size at any
/// Text size, as toolbar symbols do in Finder and Xcode: a symbol beside it (Pull's and Push's arrows) doesn't grow.
@MainActor
public final class IconButton: PointerButton {
    /// An icon button showing `image`, named `tip` (its tooltip), that calls `action`.
    public convenience init(_ image: NSImage?, tip: String, action: @escaping () -> Void) {
        self.init(image, tip: tip, target: nil, action: nil)
        onClick = action
    }

    public convenience init(_ image: NSImage?, tip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        toolTip = tip
        setAccessibilityLabel(tip)
        contentTintColor = .secondaryLabelColor
        symbolConfiguration = .chrome()
        font = .uiDigits(TextSize.caption, weight: .medium)
        self.target = target
        self.action = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// An icon alone sits in the middle of its square; with a count ("↑ 56") the icon leads it. When it led with no
    /// count, the "+" of a sidebar row stood 4 pt left of its hover square's centre.
    override public var title: String { didSet { imagePosition = title.isEmpty ? .imageOnly : .imageLeading } }
    /// VoiceOver says the tip, so a button that changes what it does (Reload → Stop) is heard by its new name.
    override public var toolTip: String? { didSet { setAccessibilityLabel(toolTip) } }

    /// True while the button is at work (Refresh while it reads). A spinner stands where the symbol was, and the
    /// symbol comes back after.
    public var busy = false {
        didSet {
            guard busy != oldValue else { return }
            crossfade()
            if busy {
                idle = image
                image = nil
                spinner.isHidden = false
                spinner.startAnimation(nil)
            } else {
                image = idle
                spinner.stopAnimation(nil)
                spinner.isHidden = true
            }
        }
    }
    private var idle: NSImage?
    private lazy var spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        return spinner
    }()

    override public var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(
            width: max(Metrics.iconButton, size.width + (title.isEmpty ? 0 : Metrics.gap)), height: Metrics.iconButton)
    }
}
