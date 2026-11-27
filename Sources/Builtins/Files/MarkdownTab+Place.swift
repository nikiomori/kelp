import AppKit
import Core

/// An agent's page opens where it was left: a canvas at the size it was zoomed to, a doc scrolled to where it was
/// read. Kept for the page in UIState (`artifacts.place:<page>`), when it is zoomed and when the tab is left.
extension MarkdownTab {
    private var placeKey: String? {
        ArtifactBar.isPage(url.path) ? "artifacts.place:" + Artifacts.projectPath(url.path) : nil
    }

    /// The place kept for this page: its zoom (nil: fitted) and how far down it was.
    var keptPlace: (zoom: Double?, y: Double) {
        let kept = placeKey.flatMap { app.uiState[$0] }
        let number = { (v: JSONValue?) -> Double? in
            switch v {
            case .double(let number)?: number
            case .int(let whole)?: Double(whole)
            default: nil
            }
        }
        return (number(kept?["zoom"]), number(kept?["y"]) ?? 0)
    }

    /// The canvas zoomed by its capsule or keys: kept for the next drawing and the next opening.
    func zoomed(_ zoom: Double?) {
        canvasZoom = zoom
        keepPlace()
    }

    /// Takes the kept zoom before the page is first drawn.
    func restorePlace() { canvasZoom = keptPlace.zoom }

    /// Keeps where the page is now.
    func keepPlace() {
        guard let key = placeKey else { return }
        let zoom = canvasZoom
        web.evaluateJavaScript("window.scrollY", in: nil, in: Self.world) { [weak self] read in
            guard let self else { return }
            var place: [String: JSONValue] = ["y": .double(keptPlace.y)]
            if case .success(let y as Double) = read { place["y"] = .double(y) }
            if let zoom { place["zoom"] = .double(zoom) }
            app.uiState[key] = .object(place)
        }
    }
}
