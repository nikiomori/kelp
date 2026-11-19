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
        let text = NSTextField.sentence(
            String(
                localized:
                    "Language servers and formatters can run code from “\(name)” (its build scripts, plugins, toolchain). Trust this project?"
            ))
        let later = TextButton(String(localized: "Not Now"), onClick: notNow)
        let yes = TextButton(String(localized: "Trust"), onClick: trust)
        return Bar.content([icon, text], [later, yes], stretching: text)
    }
}

@MainActor
extension NSTextField {
    /// A sentence in a tab's bar. A narrow tab wraps it onto a second line, which the bar's height holds at every text
    /// size, rather than cutting it mid-word ("Trust this project?" stays); past two lines the end is cut, and the
    /// tooltip has it all. Set `say` to change it, which keeps the tooltip with it.
    static func sentence(_ text: String, font: NSFont = .ui(TextSize.row)) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = font
        field.maximumNumberOfLines = 2
        field.isSelectable = false
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.say(text)
        return field
    }
    /// Shows `text` in a `sentence`, with the same in its tooltip.
    func say(_ text: String) {
        stringValue = text
        toolTip = text.isEmpty ? nil : text
    }
}
