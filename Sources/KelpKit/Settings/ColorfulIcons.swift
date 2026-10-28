import AppKit
import DesignKit

/// The "Colorful" file icon theme: icons picked by name and extension, the way VS Code icon themes do, drawn with SF Symbols
/// (or a short monogram where no symbol fits). Images draw on demand, so system colors follow light and dark.
@MainActor
enum ColorfulIcons {
    static func image(_ name: String, folder: Bool) -> NSImage {
        let (key, style) = folder ? folderStyle(name.lowercased()) : fileStyle(name.lowercased())
        if let i = cache[key] { return i }
        let i = render(style)
        cache[key] = i
        return i
    }

    private struct Style {
        var glyph: String
        var color: NSColor
        var text = false
        var badge: (glyph: String, color: NSColor)?
    }
    private static func sym(_ g: String, _ c: NSColor) -> Style { Style(glyph: g, color: c) }
    private static func text(_ t: String, _ c: NSColor) -> Style { Style(glyph: t, color: c, text: true) }
    private static func badge(_ g: String, _ c: NSColor) -> Style { Style(glyph: "folder.fill", color: folderColor, badge: (g, c)) }
    private static var cache: [String: NSImage] = [:]

    private static let plainFile = sym("doc", .secondaryLabelColor)
    /// systemYellow is too pale on white; folders are a lighter blue in dark mode, like Finder's.
    private static let yellow = NSColor.dynamic(light: NSColor(srgbRed: 0.85, green: 0.6, blue: 0, alpha: 1), dark: .systemYellow)
    private static let folderColor = NSColor.dynamic(light: .systemBlue, dark: NSColor(srgbRed: 0.42, green: 0.69, blue: 0.98, alpha: 1))

    private static func fileStyle(_ n: String) -> (String, Style) {
        if let s = byName[n] { return (n, s) }
        for (prefix, s) in byPrefix where n.hasPrefix(prefix) { return (prefix, s) }
        if n.hasSuffix(".d.ts") { return (".d.ts", text("TS", .secondaryLabelColor)) }
        let ext = (n as NSString).pathExtension
        return byExt[ext].map { ("." + ext, $0) } ?? ("", plainFile)
    }

    private static func folderStyle(_ n: String) -> (String, Style) {
        if generated.contains(n) { return ("/generated", sym("folder.fill", .systemGray.withAlphaComponent(0.55))) }
        return byFolder[n].map { ("/" + n, $0) } ?? ("/", sym("folder.fill", folderColor))
    }

    private static func table(_ rows: [([String], Style)]) -> [String: Style] {
        Dictionary(rows.flatMap { keys, s in keys.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
    }

    private static let byExt = table([
        (["swift"], sym("swift", .systemOrange)),
        (["js", "mjs", "cjs"], text("JS", yellow)),
        (["ts", "mts", "cts"], text("TS", .systemBlue)),
        (["jsx", "tsx"], sym("atom", .systemCyan)),
        (["py", "pyi", "pyw"], text("Py", .systemBlue)),
        (["go"], text("GO", .systemCyan)),
        (["rs"], text("RS", .systemRed)),
        (["rb", "erb"], sym("diamond.fill", .systemRed)),
        (["java"], sym("cup.and.saucer.fill", .systemOrange)),
        (["kt", "kts"], text("K", .systemPurple)),
        (["c"], text("C", .systemBlue)),
        (["cpp", "cc", "cxx"], text("C++", .systemBlue)),
        (["h", "hpp", "hh"], text("H", .systemPurple)),
        (["m", "mm"], text("M", .systemBlue)),
        (["cs"], text("C#", .systemPurple)),
        (["php"], text("PHP", .systemIndigo)),
        (["lua"], sym("moon.fill", .systemIndigo)),
        (["dart"], text("D", .systemTeal)),
        (["ex", "exs"], sym("drop.fill", .systemPurple)),
        (["hs", "clj", "cljs"], text("λ", .systemPurple)),
        (["zig"], text("Z", .systemOrange)),
        (["vue"], text("V", .systemGreen)),
        (["svelte"], text("S", .systemOrange)),
        (["r"], text("R", .systemBlue)),
        (["nix"], sym("snowflake", .systemCyan)),
        (["graphql", "gql"], sym("point.3.connected.trianglepath.dotted", .systemPink)),
        (["html", "htm"], sym("chevron.left.forwardslash.chevron.right", .systemOrange)),
        (["xml", "xib", "storyboard"], sym("chevron.left.forwardslash.chevron.right", .systemGreen)),
        (["css"], sym("paintbrush.pointed.fill", .systemBlue)),
        (["scss", "sass", "less"], sym("paintbrush.pointed.fill", .systemPink)),
        (["json", "jsonc", "json5"], sym("curlybraces", yellow)),
        (["yaml", "yml"], sym("list.bullet.indent", .systemPink)),
        (["toml"], sym("list.bullet.indent", .systemOrange)),
        (["ini", "cfg", "conf", "properties", "plist", "xcconfig", "entitlements"], sym("gearshape.fill", .systemGray)),
        (["md", "markdown", "mdx"], text("M↓", .systemTeal)),
        (["txt", "rtf"], sym("text.alignleft", .secondaryLabelColor)),
        (["log"], sym("list.bullet", .secondaryLabelColor)),
        (["csv", "tsv", "xlsx", "xls", "numbers"], sym("tablecells.fill", .systemGreen)),
        (["pdf"], sym("doc.richtext.fill", .systemRed)),
        (["doc", "docx", "pages"], sym("doc.text.fill", .systemBlue)),
        (["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns", "avif", "svg"], sym("photo.fill", .systemMint)),
        (["mp4", "mov", "m4v", "webm", "mkv", "avi"], sym("film.fill", .systemPink)),
        (["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "caf"], sym("waveform", .systemPurple)),
        (["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "jar"], sym("archivebox.fill", .systemBrown)),
        (["dmg", "iso", "pkg"], sym("externaldrive.fill", .systemGray)),
        (["ttf", "otf", "woff", "woff2"], sym("textformat", .systemGray)),
        (["sql", "sqlite", "sqlite3", "db"], sym("cylinder.fill", .systemCyan)),
        (["sh", "bash", "zsh", "fish", "command", "ps1", "bat", "cmd"], sym("terminal.fill", .systemGreen)),
        (["lock", "lockb", "resolved"], sym("lock.fill", .systemGray)),
        (["pem", "key", "crt", "cer", "p12", "pub"], sym("key.fill", yellow)),
        (["ipynb"], sym("book.closed.fill", .systemOrange)),
        (["diff", "patch"], sym("plus.forwardslash.minus", .systemGreen)),
        (["dockerfile"], sym("cube.fill", .systemBlue))
    ])

    private static let byName = table([
        (["package.swift"], sym("shippingbox.fill", .systemOrange)),
        (["package.json"], sym("shippingbox.fill", .systemRed)),
        (["cargo.toml"], sym("shippingbox.fill", .systemRed)),
        (["go.mod"], sym("shippingbox.fill", .systemCyan)),
        (["pyproject.toml", "requirements.txt", "setup.py", "pipfile"], sym("shippingbox.fill", .systemBlue)),
        (["gemfile", "podfile"], sym("shippingbox.fill", .systemRed)),
        (["package-lock.json", "pnpm-lock.yaml", "go.sum", "bun.lock"], sym("lock.fill", .systemGray)),
        (["tsconfig.json", "jsconfig.json"], sym("gearshape.fill", .systemBlue)),
        ([".editorconfig", ".prettierrc", ".swiftlint.yml", ".swift-format", ".clang-format", ".npmrc", ".nvmrc"], sym("gearshape.fill", .systemGray)),
        (["makefile", "gnumakefile", "cmakelists.txt", "justfile", "rakefile"], sym("hammer.fill", .systemOrange)),
        (["containerfile", ".dockerignore", "compose.yml", "compose.yaml"], sym("cube.fill", .systemBlue)),
        ([".gitignore", ".gitattributes", ".gitmodules", ".gitkeep", ".git-blame-ignore-revs"], sym("arrow.triangle.branch", .systemOrange)),
        (["claude.md", "claude.local.md"], sym("sparkle", .systemOrange)),
        (["agents.md", "gemini.md", ".cursorrules"], sym("sparkles", .systemPurple))
    ])

    /// Checked in order, after exact names.
    private static let byPrefix: [(String, Style)] = [
        ("readme", sym("info.circle.fill", .systemBlue)),
        ("license", sym("checkmark.seal.fill", yellow)), ("licence", sym("checkmark.seal.fill", yellow)),
        ("copying", sym("checkmark.seal.fill", yellow)),
        ("changelog", sym("clock.arrow.circlepath", .systemTeal)),
        ("dockerfile", sym("cube.fill", .systemBlue)), ("docker-compose", sym("cube.fill", .systemBlue)),
        (".env", sym("key.fill", yellow))
    ]

    /// Build output and dependency caches: a dimmed folder.
    private static let generated: Set<String> = ["node_modules", ".build", "build", "dist", "out", "target", "deriveddata", ".venv", "venv",
                                                 "__pycache__", ".next", ".cache", "coverage", ".swiftpm", ".gradle"]

    private static let byFolder = table([
        (["src", "source", "sources", "lib"], badge("chevron.left.forwardslash.chevron.right", .systemBlue)),
        (["test", "tests", "__tests__", "spec", "specs", "e2e"], badge("checkmark", .systemGreen)),
        (["docs", "doc", "documentation"], badge("doc.text.fill", yellow)),
        (["scripts", "script", "bin", "tools"], badge("terminal.fill", .systemGray)),
        ([".git"], badge("arrow.triangle.branch", .systemOrange)),
        ([".github", ".gitlab", ".circleci"], badge("arrow.triangle.pull", .systemGray)),
        ([".vscode", ".idea", ".config", "config", "configs", ".kelp"], badge("gearshape.fill", .systemGray)),
        ([".claude"], badge("sparkle", .systemOrange)),
        ([".cursor", ".codex", ".agents", "agents", "skills"], badge("sparkles", .systemPurple)),
        (["assets", "images", "img", "icons", "resources", "public", "static", "media"], badge("photo.fill", .systemMint)),
        (["vendor", "packages", "pods", "third_party"], badge("shippingbox.fill", .systemBrown)),
        (["extensions", "plugins"], badge("puzzlepiece.extension.fill", .systemPurple)),
        (["api", "server", "backend"], badge("network", .systemCyan)),
        (["db", "database", "migrations", "data"], badge("cylinder.fill", .systemCyan)),
        (["i18n", "l10n", "locales"], badge("globe", .systemCyan))
    ])

    // MARK: drawing (16 × 16 pt, the size every list and tab uses)

    private static func render(_ s: Style) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            if s.text { drawText(s.glyph, s.color, in: r) } else { drawSymbol(s.glyph, s.color, pointSize: 12, in: r.insetBy(dx: 0.5, dy: 1)) }
            if let b = s.badge {
                let spot = NSRect(x: 6, y: 0, width: 10, height: 10)
                NSGraphicsContext.current?.compositingOperation = .destinationOut   // a gap around the badge
                NSBezierPath(roundedRect: spot.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                drawSymbol(b.glyph, b.color, pointSize: 9, weight: .bold, in: spot)
            }
            return true
        }
    }

    /// Monochrome, tinted in a layer of its own: cut-outs (the "i" in info.circle.fill) stay transparent.
    private static func drawSymbol(_ name: String, _ color: NSColor, pointSize: CGFloat, weight: NSFont.Weight = .medium, in box: NSRect) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)),
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = min(box.width / img.size.width, box.height / img.size.height, 1)
        let size = NSSize(width: img.size.width * k, height: img.size.height * k)
        let r = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil)
        img.draw(in: r)
        color.set()
        r.fill(using: .sourceIn)
        ctx.endTransparencyLayer()
    }

    private static func drawText(_ t: String, _ color: NSColor, in r: NSRect) {
        var size: CGFloat = 12, attrs: [NSAttributedString.Key: Any] = [:]
        repeat {   // shrink until it fits the width
            let base = NSFont.systemFont(ofSize: size, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            attrs = [.font: font, .foregroundColor: color, .kern: -0.4]
            size -= 0.5
        } while (t as NSString).size(withAttributes: attrs).width > r.width && size > 6
        let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: size)
        let w = (t as NSString).size(withAttributes: attrs).width
        (t as NSString).draw(at: NSPoint(x: r.midX - w / 2, y: r.midY - (font.capHeight / 2) + font.descender), withAttributes: attrs)
    }
}
