import AppKit

/// Puts one string on the clipboard, in place of what was there.
@MainActor
package func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
