import AppKit
import Core

/// What the agent's turn changed besides what was marked: the boards of a canvas whose text differs between the
/// version the marks went with and the one the turn left, that no mark to check points at. The check bar says so, so
/// a change the user didn't ask for isn't missed.
extension MarkdownTab {
    private static let elsewhere = NSMapTable<MarkdownTab, NSArray>.weakToStrongObjects()
    var changedElsewhere: [String] { Self.elsewhere.object(forKey: self) as? [String] ?? [] }

    /// Finds them for `marks`, the page's marks as they are now.
    func findChangedElsewhere(_ marks: ArtifactMarks) async {
        let checked = marks.marks.filter { $0.state == .check }
        guard page == .canvas, let before = checked.compactMap({ $0.rounds.last?.before }).min(),
            let after = checked.compactMap({ $0.rounds.last?.after }).max(), after > before
        else { return Self.elsewhere.removeObject(forKey: self) }
        let read = { (n: Int) in
            await self.app.quiet(FilesRead(path: Artifacts.versionPath(target: self.url.path, n))).flatMap {
                CanvasSnapshot.read($0.text)
            }
        }
        guard let was = await read(before), let now = await read(after) else { return }
        let marked = Set(checked.map(\.board))
        Self.elsewhere.setObject(now.changed(since: was).filter { !marked.contains($0) } as NSArray, forKey: self)
    }
}
