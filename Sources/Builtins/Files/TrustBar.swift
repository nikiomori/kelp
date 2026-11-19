import AppKit
import DesignKit
import KelpKit

/// The bar over a code file in a project that isn't trusted to run its language server or formatter. It asks the
/// question, with Not Now and Trust. It is a bar in the tab rather than a card over it, so it moves the text down
/// instead of covering lines. Not Now hides it for the project until Kelp starts again, and the status bar's
/// "Restricted" stays and can ask too.
@MainActor
enum TrustBar {
    static func make(project name: String, notNow: @escaping () -> Void, trust: @escaping () -> Void) -> Bar {
        let icon = NSImageView(image: NSImage.symbol("info.circle"))
        icon.contentTintColor = .secondaryLabelColor
        let text = NSTextField(
            wrappingLabelWithString: String(
                localized:
                    "Language servers and formatters can run code from “\(name)” (its build scripts, plugins, toolchain). Trust this project?"
            ))
        text.font = .ui(TextSize.row)
        // A narrow tab wraps the question onto a second line, which the bar's height holds at every text size, so
        // "Trust this project?" isn't cut off; past two lines the end is cut, and the tooltip has it all.
        text.maximumNumberOfLines = 2
        text.isSelectable = false
        text.cell?.truncatesLastVisibleLine = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.toolTip = text.stringValue
        let later = TextButton(String(localized: "Not Now"), onClick: notNow)
        let yes = TextButton(String(localized: "Trust"), onClick: trust)
        return Bar.content([icon, text], [later, yes], stretching: text)
    }
}
