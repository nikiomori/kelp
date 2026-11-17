import AppKit
import Core
import DesignKit
import SwiftUI

/// What the settings change, drawn with them as they are and with the shell's themes, for the sections that show them
/// over their rows (`SettingsSection.previews`) or as a choice's picture (`SettingChoices.picture`). Each follows a
/// change at once, so a row is tried by looking up.
@MainActor
package enum SettingSamples {
    /// A prompt and a command in the terminal's font, size, colours and cursor.
    package static func terminal() -> AnyView { AnyView(TerminalSample()) }
    /// A cursor style, in the terminal's own colours.
    package static func cursor(_ option: String) -> AnyView { AnyView(CursorPicture(option: option)) }
}

/// A prompt and a command in the terminal's font, size, colors and cursor. Ghostty draws the real one; this is text in the
/// same font, so its cell spacing can differ a little.
private struct TerminalSample: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings, colors = app.themes.shown?.terminal
        let size = CGFloat(settings[SettingKeys.terminalFontSize])
        let font =
            NSFont(name: settings[SettingKeys.terminalFontFamily], size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let fg = colors.flatMap { NSColor(hex: $0.foreground) }.map(Color.init) ?? .primary
        let palette = colors?.palette ?? []
        let tint = { (index: Int) in palette.count > index ? NSColor(hex: palette[index]).map(Color.init) ?? fg : fg }
        VStack(alignment: .leading, spacing: 2) {
            (Text(verbatim: "~/projects/kelp ").foregroundStyle(tint(4))
                + Text(verbatim: "main").foregroundStyle(tint(2)))
            HStack(spacing: 0) {
                Text(verbatim: "❯ swift build ").foregroundStyle(fg)
                cursor(size).foregroundStyle(
                    Color(nsColor: colors?.cursor.flatMap { NSColor(hex: $0) } ?? .controlAccentColor))
            }
        }
        .font(Font(font))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.inset)
        .background(
            Color(nsColor: app.themes.terminalBackground),
            in: RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
        )
        // Its edge: a light theme's terminal is as white as the card it sits on.
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).strokeBorder(
                Color.primary.opacity(0.12))
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cursor(_ size: CGFloat) -> some View {
        switch app.settings[SettingKeys.cursorStyle] {
        case "bar": Rectangle().frame(width: 2, height: size * 1.25)
        case "underline": Rectangle().frame(width: size * 0.6, height: 2).frame(height: size * 1.25, alignment: .bottom)
        default: Rectangle().frame(width: size * 0.6, height: size * 1.25)
        }
    }
}
