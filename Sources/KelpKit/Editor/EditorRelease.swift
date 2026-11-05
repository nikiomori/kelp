import Foundation
import WorkbenchKit

/// A hidden terminal costs about 25 MB (its surface and scrollback; measured with 8 tabs, 2026-11-05). The tabs on
/// screen and the last few shown stay built; older hidden ones let go of it and attach again, history and all, when shown.
extension EditorArea {
    static let keptHidden = 2

    /// `shown` was just on screen in its group: it moves to the front, and terminals hidden longest are released.
    func noteShown(_ shown: String?) {
        if let shown { recent.removeAll { $0 == shown }; recent.append(shown) }
        let onScreen = Set(layout.groups.values.compactMap { $0.selectedTab?.id })
        let hidden = recent.filter { !onScreen.contains($0) && contents[$0] != nil }
        for id in hidden.dropLast(Self.keptHidden) {
            guard let c = contents[id], TabURI.scheme(c.uri) == "session", !c.isEdited else { continue }
            contents[id] = nil
        }
        recent.removeAll { contents[$0] == nil && !onScreen.contains($0) }
    }
}
