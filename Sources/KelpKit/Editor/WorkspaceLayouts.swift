// Every workspace's layout, kept in one place whether or not its editor area is loaded.
import DesignKit
import Foundation
import Observation
import WorkbenchKit

/// Each workspace's tabs in their split tree, by workspace id (`app.workbench.layouts`). A layout is read from
/// `UIState` the first time it is asked for, and saved there half a second after it last changed. This is the one owner
/// of every layout: an editor area draws its workspace's layout from here and follows it (`track`), and a tab opened,
/// closed or replaced in a workspace that isn't on screen lands here too, whether that workspace is loaded or not.
@MainActor
final class WorkspaceLayouts {
    /// One workspace's layout, observed on its own, so a change to it wakes only what shows that workspace.
    @MainActor @Observable
    final class Entry {
        var layout: WorkspaceLayout
        init(_ layout: WorkspaceLayout) { self.layout = layout }
    }

    private let state: UIState
    private var entries: [String: Entry] = [:]
    private var unsaved: Set<String> = []
    private let saveWork = Debounce()

    init(state: UIState) { self.state = state }

    subscript(id: String) -> WorkspaceLayout {
        get { entry(id).layout }
        set {
            let entry = entry(id)
            guard entry.layout != newValue else { return }
            entry.layout = newValue
            unsaved.insert(id)
            saveWork.after(0.5) { [weak self] in self?.save() }   // a divider dragged changes it many times a second
        }
    }

    private func entry(_ id: String) -> Entry {
        if let entry = entries[id] { return entry }
        let entry = Entry(.load(id, from: state))
        entries[id] = entry
        return entry
    }

    /// Saves now what is waiting out the pause, for quitting (a tab moved in the last half second).
    func save() {
        saveWork.cancel()
        for id in unsaved { entries[id]?.layout.save(id, to: state) }
        unsaved = []
    }

    /// Forgets the layout of a workspace that is gone (the daemon removes the saved one).
    func forget(_ id: String) {
        entries[id] = nil
        unsaved.remove(id)
    }
}
