import AppKit
import Core
import Observation
import os

/// Finds agents' icons. Each is the logo Kelp ships (`logo`), else the vendor's Mac app when it's installed, else the
/// icon the agent's website serves, fetched once and kept in ~/.kelp/icons. Fetched monochrome logos sit on a small
/// tile so they show in light and dark mode. Until an icon is found (or if none is), the agent's SF Symbol stands in.
@MainActor
@Observable
final class AgentIcons {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var asked = Set<String>()

    /// The images `AgentCatalog.icon` made, by agent and size, each with the icon it came from.
    @ObservationIgnored var made: [String: (source: NSImage?, image: NSImage)] = [:]
    /// Grey copies of made images, kept because rendering one takes a millisecond or more, for each paused row on
    /// each sidebar pass.
    @ObservationIgnored private var greys: [ObjectIdentifier: (image: NSImage, grey: NSImage)] = [:]

    func grey(_ image: NSImage) -> NSImage {
        if let known = greys[ObjectIdentifier(image)] { return known.grey }
        let grey = image.grayscale
        greys[ObjectIdentifier(image)] = (image, grey)   // holding the image keeps its identifier from being reused
        return grey
    }

    /// Returns the agent's icon. `apps` and `site` are where the agent's manifest says the icon comes from when Kelp
    /// ships none.
    func image(_ id: String, apps: [String], site: String?) -> NSImage? {
        if !asked.contains(id) {
            asked.insert(id)
            load(id, apps: apps, site: site)
        }
        return images[id]
    }

    private var folder: URL { Paths.root.appendingPathComponent("icons") }

    private func load(_ id: String, apps: [String], site: String?) {
        if let logo = Self.logo(id) {
            images[id] = logo
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for name in apps {
            for dir in ["/Applications", "\(home)/Applications"]
            where FileManager.default.fileExists(atPath: "\(dir)/\(name).app") {
                images[id] = IconTile.app(NSWorkspace.shared.icon(forFile: "\(dir)/\(name).app"))
                return
            }
        }
        let cached = folder.appendingPathComponent("\(id).icon")
        if let data = try? Data(contentsOf: cached), let img = Self.tile(data) {
            images[id] = img
            return
        }
        guard let site else { return }
        let dir = folder
        Task.detached(priority: .utility) {
            guard let data = await Self.fetchIcon(site) else { return }
            // The icon shows either way; a cache that can't be written is fetched again next launch, and says why.
            Logger.kelp("icons").attempt("caching \(id)'s icon") {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: cached)
            }
            await MainActor.run { self.images[id] = Self.tile(data) }
        }
    }

    // MARK: fetching

    nonisolated private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Kelp", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
            (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// Whether the data is an image, and not the HTML page some sites send for any path.
    nonisolated static func isImage(_ d: Data) -> Bool {
        // swiftlint:disable:next optional_data_string_conversion
        let head = String(decoding: d.prefix(256), as: UTF8.self).lowercased()   // lossy on purpose, to sniff bytes
        return !head.contains("<!doctype html") && !head.contains("<html") && NSImage(data: d) != nil
    }

    /// Fetches the site's touch icon or favicon, or failing that, the icons its home page links to.
    nonisolated static func fetchIcon(_ site: String) async -> Data? {
        guard let base = URL(string: "https://\(site)/") else { return nil }
        for path in ["apple-touch-icon.png", "favicon.ico"] {
            if let url = URL(string: path, relativeTo: base), let data = await get(url), isImage(data) { return data }
        }
        guard let page = await get(base), let html = String(data: page, encoding: .utf8) else { return nil }
        let links = html.matches(of: #/<link[^>]*>/#).map { String($0.output) }.filter {
            $0.lowercased().contains("icon")
        }
        let ordered = links.filter { $0.contains("apple-touch") } + links.filter { !$0.contains("apple-touch") }
        for tag in ordered {
            // The href may be quoted or not, because charm.land writes href=/touchicon_180w.png.
            guard let href = tag.firstMatch(of: #/href=["']?([^"'\s>]+)/#)?.output.1,
                let url = URL(string: String(href).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)
            else { continue }
            if let data = await get(url), isImage(data) { return data }
        }
        return nil
    }

    // MARK: drawing

    /// Returns the logo Kelp ships for the agent (Resources/AgentLogos, from Lobe Icons). It is the same mark
    /// everywhere, in its own colours and on no tile. A one-colour logo (`<id>-mono.svg`) is drawn in the text colour
    /// of the current appearance.
    static func logo(_ id: String) -> NSImage? {
        let mono = Bundle.module.image(forResource: "\(id)-mono")
        guard let svg = mono ?? Bundle.module.image(forResource: id) else { return nil }
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            // AppKit sometimes asks an image view to draw with no context (for a view a stack has set aside). Nothing
            // can be drawn then, and `fill(using:)` traps without a context.
            guard NSGraphicsContext.current != nil else { return false }
            svg.draw(in: rect.insetBy(dx: 2, dy: 2))   // the marks fill their square, unlike a tile's art
            if mono != nil {
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        img.cacheMode = .never   // drawn again for each appearance
        return img
    }

    /// Returns an app-like rounded icon, the same tile shape for every agent. A logo on a transparent background sits
    /// on a tile, which is the opposite tone when the logo is monochrome and white when it's in colour. Artwork that
    /// fills its square is clipped to the tile.
    static func tile(_ data: Data) -> NSImage? {
        guard let logo = NSImage(data: data) else { return nil }
        let side: CGFloat = 32
        let tone = luminance(logo), clear = transparent(logo)
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            if tone != nil || clear {
                (tone.map { $0 < 0.5 } ?? true ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.14, alpha: 1))
                    .setFill()
                path.fill()
                logo.draw(in: rect.insetBy(dx: 6, dy: 6))
            } else {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                logo.draw(in: rect)   // a full-colour icon fills its square
                NSGraphicsContext.restoreGraphicsState()
            }
            IconTile.edge(rect)
            return true
        }
        img.cacheMode = .never   // the tile's edge is drawn again for each appearance
        return img
    }

    /// Whether more than a fifth of the logo is see-through, which makes it a mark rather than a square app icon.
    private static func transparent(_ img: NSImage) -> Bool {
        pixels(img).filter { $0.alphaComponent < 0.3 }.count > 16 * 16 / 5
    }

    /// Average lightness of the opaque pixels — nil for colorful or fully opaque artwork, which needs no tile.
    private static func luminance(_ img: NSImage) -> CGFloat? {
        var sum: CGFloat = 0, count: CGFloat = 0, transparent = 0, saturated: CGFloat = 0
        for c in pixels(img) {
            if c.alphaComponent < 0.3 {
                transparent += 1
                continue
            }
            sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3
            count += 1
            saturated +=
                max(c.redComponent, c.greenComponent, c.blueComponent)
                - min(c.redComponent, c.greenComponent, c.blueComponent)
        }
        // A logo on transparency without much color is monochrome, so it needs contrast behind it.
        guard count > 0, transparent > 16 * 16 / 5, saturated / count < 0.25 else { return nil }
        return sum / count
    }

    /// The logo drawn 16×16, pixel by pixel.
    private static func pixels(_ img: NSImage) -> [NSColor] {
        let side = 16
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<side).flatMap { column in (0..<side).compactMap { rep.colorAt(x: column, y: $0) } }
    }
}
