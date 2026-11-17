import Foundation
import IOKit.pwr_mgt
import os

/// Keeps the Mac awake while agents work, with one IOKit assertion at a time. The ticker and settings changes apply it.
final class KeepAwake: Sendable {
    /// The assertion held now, and its type (nil: none).
    let held = OSAllocatedUnfairLock<(id: UInt32, type: String?)>(initialState: (0, nil))

    /// keepAwake: "always" | "agents" (only while an agent is working, `working`) | "off".
    /// "always" is Caffeine: the screen stays on too. Agents only need the Mac itself, so the screen may still sleep and lock.
    func apply(_ mode: String, working: Bool) {
        let want =
            mode == "always"
            ? kIOPMAssertPreventUserIdleDisplaySleep
            : mode == "agents" && working ? kIOPMAssertPreventUserIdleSystemSleep : nil
        held.withLock { held in   // the ticker and a settings change may run at once: keep one assertion
            guard held.type != want else { return }
            Self.release(&held)
            guard let want else { return }
            var id: IOPMAssertionID = 0
            let name = mode == "always" ? "Keep Mac Awake is on in Kelp" : "Kelp agents are working"
            if IOPMAssertionCreateWithName(
                want as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id) == kIOReturnSuccess
            {
                held = (id, want)
            }
        }
    }

    /// Releases the assertion (on a hand-over, the next kelpd takes its own).
    func release() { held.withLock { Self.release(&$0) } }

    private static func release(_ held: inout (id: UInt32, type: String?)) {
        guard held.id != 0 else { return }
        IOPMAssertionRelease(held.id)
        held = (0, nil)
    }
}
