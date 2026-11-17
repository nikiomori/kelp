// Who has an agent's page: the agent; the user, who took it with a click or a key (or Take Over); the user, because the
// agent asked them to do something there (`kelp browser ask`).
import AppKit
import Core
import DesignKit
import KelpKit

extension BrowserTab {
    /// How long the user may leave a page they took before the strip asks whether to hand it back.
    static let remindAfter: TimeInterval = 120

    /// The user's own clicks and keys in the page, while an agent drives it: the first one takes the page (scrolling and
    /// pointing don't). A key with ⌘ is a shortcut (copy, find), not typing into the page.
    func watchUser() {
        guard userWatch == nil else { return }
        userWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
            [weak self] event in
            self?.userActed(event)
            return event
        }
    }

    func stopWatchingUser() {
        if let userWatch { NSEvent.removeMonitor(userWatch) }
        userWatch = nil
    }

    private func userActed(_ event: NSEvent) {
        guard let drive, let window = web.window, event.window === window else { return }
        let inPage =
            event.type == .keyDown
            ? !event.modifierFlags.contains(.command)
                && (window.firstResponder as? NSView)?.isDescendant(of: web) == true
            : web.bounds.contains(web.convert(event.locationInWindow, from: nil))
        guard inPage else { return }
        drive.userAt = Date()
        if !drive.takenOver {
            drive.takenOver = true
            showAgentBar()
        }
        // The reminder, once they've left it alone that long.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.remindAfter + 1) { [weak self] in
            MainActor.assumeIsolated { self?.showAgentBar() }   // main queue
        }
    }

    /// `kelp browser ask`: with `text`, the page goes to the user and its strip asks them; with `ended`, the question
    /// is over, and the page goes back to the agent when the user said Done (`allow`). The answer is wherever the page
    /// is now.
    func ask(_ args: JSONValue) async throws -> JSONValue {
        guard let drive else { throw RPCError.invalidParams("That tab shows no page of an agent's.") }
        if let text = args["text"]?.string {
            drive.asked = (text, args["session"]?.string ?? "")
            drive.takenOver = true
            drive.userAt = Date()
            showAgentBar()
            return .object(["asked": .string(text)])
        }
        let done = args["ended"]?.string == "allow"
        drive.asked = nil
        drive.takenOver = !done
        showAgentBar()
        return try await settled()
    }

    /// Done on the strip: the agent's question is answered (as Allow on its row would), the page goes back to it.
    func done() {
        guard let asked = drive?.asked else { return }
        drive?.takenOver = false
        showAgentBar()
        let question = UIBrowserAsk.rowQuestion(asked.text)
        Task { await app.call(SessionChoose(id: asked.session, answer: "allow", question: question)) }
    }

    /// Who drives the page, as the user reads it: a subagent (`who`) by what it was asked, else the agent's name.
    func driverName(_ who: String) -> String {
        let session = drive?.driver.flatMap { app.session($0) }
        guard !who.isEmpty else { return session.map { app.catalog.name($0.agent) } ?? String(localized: "The agent") }
        let run = session?.runningSubagents.first { $0.id == who }
        return run.flatMap { $0.task ?? ($0.kind.isEmpty ? nil : $0.kind) } ?? String(localized: "A subagent")
    }

    /// What the strip says and offers now: who has the page, and the one thing to do about it.
    func stripLook() -> (text: String, button: String, tip: String) {
        guard let drive else { return ("", "", "") }
        let who = driverName(drive.subagent ?? "")
        if let asked = drive.asked {
            return (
                String(localized: "\(who) asks: \(asked.text)"), String(localized: "Done"),
                String(localized: "Give the page back to \(who): it goes on from here")
            )
        }
        if drive.takenOver {
            let idle = Date().timeIntervalSince(drive.userAt) >= Self.remindAfter
            return (
                idle
                    ? String(localized: "You have this page · hand it back to \(who)?")
                    : String(localized: "You have this page · \(who) waits"),
                String(localized: "Hand Back"), String(localized: "Let \(who) click and type here again")
            )
        }
        return (
            String(localized: "\(who) is using this page"), String(localized: "Take Over"),
            String(localized: "Your first click or key in the page takes it too; scrolling doesn't")
        )
    }
}
