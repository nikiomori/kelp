import Core
import Foundation

/// Discards with an Undo, for the diff and Source Control (Git) and a file's change bars (Files): `discard`, given the
/// name the daemon keeps the thrown-away changes under, goes at once; once it's done a banner says `text`, and its
/// Undo puts them back, on screen as long as the daemon keeps them (a minute). A discard that fails says why instead.
@MainActor
package func discardWithUndo<Method: RPCMethod>(
    _ app: AppModel, _ discard: (_ undo: String) -> Method, saying text: String, worktree wid: String,
    then reload: @escaping @MainActor () async -> Void = {}
) async {
    let undo = UUID().uuidString
    if await app.call(discard(undo)) != nil {
        Banner.show(
            text,
            action: (
                String(localized: "Undo"),
                {
                    Task {
                        if await app.call(GitUndoDiscard(id: wid, undo: undo)) != nil { await reload() }
                        app.watchAgain(.git, app.gitKey(wid))
                    }
                }
            ), lasts: 60)
    }
    app.watchAgain(.git, app.gitKey(wid))   // Source Control and the badges now, not on the next file event
}
