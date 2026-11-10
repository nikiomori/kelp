import AppKit
import DesignKit
import KelpKit

/// Over a code file of a project not trusted to run its language server or formatter: the question, with Not Now and
/// Trust. A bar in the tab, not a card over it: it moves the text down instead of covering its lines. Not Now hides it
/// for the project until Kelp starts again; the status bar's "Restricted" stays and asks too.
@MainActor
enum TrustBar {
    static func make(project name: String, notNow: @escaping () -> Void, trust: @escaping () -> Void) -> Bar {
        let icon = NSImageView(image: NSImage.symbol("info.circle"))
        icon.contentTintColor = .secondaryLabelColor
        let text = NSTextField(
            labelWithString: String(
                localized:
                    "Language servers and formatters can run code from “\(name)” (its build scripts, plugins, toolchain). Trust this project?"
            ))
        text.font = .ui(TextSize.row)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.toolTip = text.stringValue
        let later = TextButton(String(localized: "Not Now"), onClick: notNow)
        let yes = TextButton(String(localized: "Trust"), onClick: trust)
        return Bar.content([icon, text], [later, yes], stretching: text)
    }
}
