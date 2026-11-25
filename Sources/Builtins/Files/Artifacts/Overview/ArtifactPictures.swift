import AppKit
import Core
import CryptoKit
import KelpKit

/// The pictures on Artifacts Overview's cards. `ArtifactShots` draws one page at a time, so the cards on screen wait
/// in a line, first come first drawn, and a card that scrolls away leaves it. Each picture is kept as a PNG in Kelp's
/// home (`artifact-pictures`), named by the page's file, its last change and the appearance, so a page is drawn once
/// per change rather than at every opening. Limit: old pictures stay until the folder is emptied by hand; a page's
/// change leaves its earlier picture behind.
@MainActor
@Observable
final class ArtifactPictures {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let shots = ArtifactShots()
    @ObservationIgnored private var line: [Wanted] = []
    @ObservationIgnored private var drawing = false
    @ObservationIgnored private let folder: URL
    /// False once a picture couldn't be written: the pictures are then kept for this run only.
    @ObservationIgnored private var keepsOnDisk = true

    private struct Wanted {
        let key: String, path: String, version: Double, dark: Bool, board: Bool
    }

    init(app: AppModel, folder: URL = Paths.root.appendingPathComponent("artifact-pictures")) {
        self.app = app
        self.folder = folder
    }

    /// What names the picture of `item` in `dark` or light: nil for a page with nothing to show.
    static func key(_ item: ArtifactItem, dark: Bool) -> String? {
        item.preview.map { "\($0)|\(item.modified ?? item.created)|\(dark)" }
    }

    func image(_ item: ArtifactItem, dark: Bool) -> NSImage? { Self.key(item, dark: dark).flatMap { images[$0] } }

    /// A card showed: its picture comes from the disk, or is drawn in its turn.
    func want(_ item: ArtifactItem, dark: Bool) {
        guard let key = Self.key(item, dark: dark), let path = item.preview, images[key] == nil,
            !line.contains(where: { $0.key == key })
        else { return }
        if let kept = NSImage(contentsOf: file(key)) {
            images[key] = kept
            return
        }
        line.append(
            Wanted(
                key: key, path: path, version: item.modified ?? item.created, dark: dark,
                board: item.type == Artifacts.Kind.design.rawValue))
        drawNext()
    }

    /// A card went off screen before its turn: it leaves the line.
    func unwant(_ item: ArtifactItem, dark: Bool) {
        guard let key = Self.key(item, dark: dark) else { return }
        line.removeAll { $0.key == key }
    }

    private func drawNext() {
        guard !drawing, !line.isEmpty else { return }
        drawing = true
        let next = line.removeFirst()
        Task {
            if let image = await shots.picture(
                file: next.path, version: next.version, dark: next.dark, board: next.board, app: app)
            {
                images[next.key] = image
                keep(image, as: next.key)
            }
            drawing = false
            drawNext()
        }
    }

    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".png")
    }

    private func keep(_ image: NSImage, as key: String) {
        guard keepsOnDisk, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        do {
            try Paths.ensure(folder)
            try png.write(to: file(key), options: .atomic)
        } catch {
            keepsOnDisk = false   // a full or locked disk: draw them again next time rather than try each one
        }
    }
}
