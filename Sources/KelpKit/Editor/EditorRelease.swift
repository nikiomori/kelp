import Foundation
import WorkbenchKit

/// A hidden terminal costs about 25 MB (its surface and scrollback; measured with 8 tabs, 2026-11-05). The tabs on
/// screen and the last few shown stay built; older ones hidden a while let go of it and attach again when shown, with the
/// daemon's last megabyte of output (`LiveSession.ringLimit`): a look at other tabs keeps all of a terminal's scrollback.
extension EditorArea {
    static let keptHidden = 2
    static let releaseAfter: TimeInterval = 300

    /// `shown` was just on screen in its group: it moves to the front, and terminals hidden longest are released.
    func noteShown(_ shown: String?, now: Date = Date()) {
        if let shown { recent.removeAll { $0 == shown }; recent.append(shown) }
        let onScreen = Set(layout.groups.values.compactMap { $0.selectedTab?.id })
        let hidden = recent.filter { !onScreen.contains($0) && contents[$0] != nil }
        hiddenAt = hiddenAt.filter { hidden.contains($0.key) }
        for id in hidden where hiddenAt[id] == nil { hiddenAt[id] = now }
        for id in hidden.dropLast(Self.keptHidden) where now.timeIntervalSince(hiddenAt[id] ?? now) >= Self.releaseAfter {
            guard let c = contents[id], TabURI.scheme(c.uri) == "session", !c.isEdited else { continue }
            contents[id] = nil
        }
        recent.removeAll { contents[$0] == nil && !onScreen.contains($0) }
    }
}
