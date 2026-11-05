import AppKit
import WebKit
import KelpKit

/// What a page asks: `alert`, `confirm`, `prompt`, and a file to upload. Without a UI delegate WebKit answered them all
/// with "no" and showed nothing. The user's pages ask the user, in a sheet. An agent's page (until the user takes it
/// over) answers for the agent: with what `kelp browser dialog` said ahead, else OK to an alert and no to the rest;
/// either way it's in the console and in the action's answer, so the agent knows it was asked.
extension BrowserTab: WKUIDelegate {
    /// The agent answers this page's questions: a page it drives (its own, or the user's it was let into, while it still
    /// does: ten minutes after its last action that tab is the user's again), not taken over.
    var agentAnswers: Bool { watching && !takenOver && (agent || Date().timeIntervalSince(drivenAt) < 600) }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        if agentAnswers { _ = agentAnswer("alert", message, fallback: true); return }
        _ = await ask(message, from: frame, buttons: [String(localized: "OK")])
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        if agentAnswers { return agentAnswer("confirm", message, fallback: false).accept }
        return await ask(message, from: frame, buttons: [String(localized: "OK"), String(localized: "Cancel")]) == .alertFirstButtonReturn
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        if agentAnswers {
            let a = agentAnswer("prompt", prompt, fallback: false)
            return a.accept ? a.text ?? defaultText ?? "" : nil
        }
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 260
        let r = await ask(prompt, from: frame, buttons: [String(localized: "OK"), String(localized: "Cancel")], field: field)
        return r == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        if agentAnswers {
            noteDialog("file chooser → cancelled (upload with kelp browser upload <ref> <file>)")
            return nil
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        panel.canChooseDirectories = p.allowsDirectories
        return await runSheet(panel) == .OK ? panel.urls : nil
    }

    /// The answer `kelp browser dialog` left (used once), else `fallback`; noted where the agent reads.
    private func agentAnswer(_ kind: String, _ message: String, fallback: Bool) -> (accept: Bool, text: String?) {
        let told = dialogAnswer != nil, a = dialogAnswer ?? (fallback, nil)
        dialogAnswer = nil
        let shown = String(message.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        let how = kind == "alert" ? "OK" : a.accept ? "accepted" + (a.text.map { " with \"\($0)\"" } ?? "")
            : "dismissed" + (told ? "" : " (kelp browser dialog accept answers the next one)")
        noteDialog("\(kind) \"\(shown)\" → \(how)")
        return a
    }

    /// A dialog the agent's page answered: in its console, and in the answer of the action that brought it up.
    func noteDialog(_ s: String) {
        noteLog("[dialog] " + s)
        dialogs.append(s)
        if dialogs.count > Self.keep { dialogs.removeFirst(dialogs.count - Self.keep) }   // `while (true) alert()` stays bounded
    }

    /// The page's question as a sheet: who asks (the frame's host, as Safari says it), what, and the buttons.
    private func ask(_ message: String, from frame: WKFrameInfo, buttons: [String], field: NSTextField? = nil) async
        -> NSApplication.ModalResponse {
        let a = NSAlert()
        let host = frame.securityOrigin.host
        a.messageText = host.isEmpty ? String(localized: "This page says") : String(localized: "\(host) says")
        a.informativeText = message
        for b in buttons { a.addButton(withTitle: b) }
        a.accessoryView = field
        if let field { a.window.initialFirstResponder = field }
        return await runSheet(a)
    }
}
