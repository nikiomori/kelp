import AppKit
import DesignKit
import KelpKit
import WebKit

/// Handles what a page asks for: `alert`, `confirm`, `prompt`, and a file to upload. Without a UI delegate, WebKit
/// answered them all with "no" and showed nothing. The user's pages ask the user in a sheet. An agent's page (until the
/// user takes it over) answers for the agent, with what `kelp browser dialog` set ahead, or else OK to an alert and no
/// to the rest. Either way the question goes in the console and in the action's answer, so the agent knows it was
/// asked.
extension BrowserTab: WKUIDelegate {
    /// Whether the agent answers this page's questions. It does on a page it drives that wasn't taken over: the agent's
    /// own page, or a user's page the agent was let into, while it still drives it. Ten minutes after the agent's last
    /// action, that tab is the user's again.
    var agentAnswers: Bool {
        guard let drive, !drive.takenOver else { return false }
        return agent || Date().timeIntervalSince(drive.drivenAt) < 600
    }

    /// The web views of windows that the user's pages opened, by their tab's address. Each is kept until its tab takes
    /// it (`BrowserTab.init`).
    static var opened: [String: WKWebView] = [:]

    /// Handles a link to a new window (`target=_blank`, `window.open`), which WebKit dropped without this. The user's
    /// page opens it in a new tab beside it, in the web view WebKit made. That web view keeps `window.opener`, so a
    /// sign-in popup can post back and close. A page an agent drives (one page per agent) loads the link itself, so the
    /// agent sees where it led.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if agent || agentAnswers {
            webView.load(navigationAction.request)
            return nil
        }
        if let url = navigationAction.request.url, !["http", "https", "about"].contains(url.scheme?.lowercased()) {
            PreviewLinks.openOutside(url)   // a mailto: link opens in Mail; other schemes get a banner
            return nil
        }
        configuration.userContentController = WKUserContentController()   // so the opener tab's handlers stay with it
        let popup = WKWebView(frame: .zero, configuration: configuration)
        let key = "about:blank#opened-\(UUID().uuidString.prefix(6))"
        Self.opened[key] = popup
        app.workbench.open(key)
        return popup
    }

    /// Closes the tab when the page closes its window (`window.close()`, a sign-in popup that's done).
    func webViewDidClose(_ webView: WKWebView) {
        app.workbench.closeTab(uri: uri, remember: false)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async {
        if agentAnswers {
            _ = agentAnswer("alert", message, fallback: true)
            return
        }
        _ = await ask(message, from: frame, buttons: [String(localized: "OK")])
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        if agentAnswers { return agentAnswer("confirm", message, fallback: false).accept }
        return await ask(message, from: frame, buttons: [String(localized: "OK"), String(localized: "Cancel")])
            == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        if agentAnswers {
            let answer = agentAnswer("prompt", prompt, fallback: false)
            return answer.accept ? answer.text ?? defaultText ?? "" : nil
        }
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 260
        let response = await ask(
            prompt, from: frame, buttons: [String(localized: "OK"), String(localized: "Cancel")], field: field)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo
    ) async
        -> [URL]?
    {
        if agentAnswers {
            noteDialog("file chooser → cancelled (upload with kelp browser upload <ref> <file>)")
            return nil
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await runSheet(panel) == .OK ? panel.urls : nil
    }

    /// Returns the answer that `kelp browser dialog` left (used once), or else `fallback`, and notes it where the agent
    /// reads.
    private func agentAnswer(_ kind: String, _ message: String, fallback: Bool) -> (accept: Bool, text: String?) {
        let told = drive?.dialogAnswer != nil, answer = drive?.dialogAnswer ?? (fallback, nil)
        drive?.dialogAnswer = nil
        let shown = String(message.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        let how =
            kind == "alert"
            ? "OK"
            : answer.accept
                ? "accepted" + (answer.text.map { " with \"\($0)\"" } ?? "")
                : "dismissed" + (told ? "" : " (kelp browser dialog accept answers the next one)")
        noteDialog("\(kind) \"\(shown)\" → \(how)")
        return answer
    }

    /// Notes a dialog the agent's page answered, in the page's console and in the answer of the action that brought it
    /// up.
    func noteDialog(_ line: String) {
        noteLog("[dialog] " + line)
        if let drive { AgentDrive.add(line, to: &drive.dialogs) }
    }

    /// Shows the page's question in a sheet, with who asks (the frame's host, as Safari puts it), the question and the
    /// buttons.
    private func ask(_ message: String, from frame: WKFrameInfo, buttons: [String], field: NSTextField? = nil) async
        -> NSApplication.ModalResponse
    {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? String(localized: "This page says") : String(localized: "\(host) says")
        alert.informativeText = message
        for title in buttons { alert.addButton(withTitle: title) }
        alert.accessoryView = field
        if let field { alert.window.initialFirstResponder = field }
        return await runSheet(alert)
    }
}
