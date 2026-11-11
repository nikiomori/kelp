import AppKit
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

/// Files a page hands over instead of showing: a link with `download`, an attachment, a type WebKit can't show. Without
/// this they were cancelled without a word. The user's go to ~/Downloads as Safari's do (a new name beside one already
/// there, the Downloads stack bounces, a banner shows it in Finder); a page an agent drives keeps its own in a folder of
/// Kelp's in the temporary directory, said in the action's answer and console. Each is marked as downloaded from the
/// web (quarantine), so Gatekeeper looks at it before it opens.
extension BrowserTab: WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences)
        async
        -> (WKNavigationActionPolicy, WKWebpagePreferences)
    {
        if let url = action.request.url, leavesSharedSite(url, mainFrame: action.targetFrame?.isMainFrame != false) {
            noteLog("[blocked] \(url.absoluteString): another site than the one the user let the agent use")
            return (.cancel, preferences)
        }
        // mailto:, tel:, an app's own scheme: WebKit would show its error page over the page the link was on.
        if let url = action.request.url, !Self.inPage.contains(url.scheme?.lowercased() ?? "") {
            if agentAnswers {
                noteLog("[blocked] \(url.absoluteString): not a web page")
            } else if action.navigationType == .linkActivated {
                PreviewLinks.openOutside(url)   // mail goes out, the rest is refused with a banner
            }
            return (.cancel, preferences)
        }
        if action.shouldPerformDownload { downloadDecided = Date() }
        return (action.shouldPerformDownload ? .download : .allow, preferences)
    }

    /// The user let the agent into their logged-in browser for one site (`open --shared`): while the agent drives the page,
    /// it stays on that site; another one is asked for again.
    func leavesSharedSite(_ url: URL, mainFrame: Bool) -> Bool {
        guard agentAnswers, !agent, mainFrame, url.scheme != "about",
            let allowed = URL(string: start).flatMap(PageOrigin.of)
        else { return false }
        return PageOrigin.of(url) != allowed
    }

    /// Schemes a page loads itself; any other is a link out of the page.
    private static let inPage: Set<String> = ["http", "https", "about", "file", "data", "blob", "javascript"]

    /// Sites the user let download this run.
    static var downloadsAllowed: Set<String> = []

    private static func allowDownloads(from host: String) async -> Bool {
        await confirm(
            String(localized: "Allow downloads from \(host)?"),
            detail: String(localized: "Its files go to your Downloads folder."), action: String(localized: "Allow"),
            cancel: String(localized: "Don't Allow"))
    }

    /// What the page answered is a file to keep: not a type WebKit shows, or sent as an attachment.
    static func downloads(_ navigationResponse: WKNavigationResponse) -> Bool {
        let disposition =
            (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return !navigationResponse.canShowMIMEType || disposition.lowercased().hasPrefix("attachment")
    }

    func webView(_ webView: WKWebView, navigationAction action: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(
        _ webView: WKWebView, navigationResponse response: WKNavigationResponse, didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename name: String)
        async -> URL?
    {
        downloadDecided = nil
        // The user's pages ask once per site, as Safari does: a page can't fill ~/Downloads unasked.
        if !agentAnswers, let host = response.url?.host ?? web.url?.host, !Self.downloadsAllowed.contains(host) {
            guard await Self.allowDownloads(from: host) else { return nil }
            Self.downloadsAllowed.insert(host)
        }
        let dir =
            agentAnswers
            ? FileManager.default.temporaryDirectory.appendingPathComponent("kelp-downloads", isDirectory: true)
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            failed(name, error)
            return nil
        }
        let safe = (name as NSString).lastPathComponent.isEmpty ? "download" : (name as NSString).lastPathComponent
        // Taken: on disk, or the path of a download still coming (two "report.pdf" at once).
        let coming = Set(downloading.values.map(\.0))
        let to = Self.free(safe, in: dir) { coming.contains($0) || FileManager.default.fileExists(atPath: $0.path) }
        downloading[ObjectIdentifier(download)] = (to, response.url, web.url)
        if agentAnswers { noteDownload("\(safe) → \(to.path) (started)") }
        return to
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let (to, source, page) = downloading.removeValue(forKey: ObjectIdentifier(download)) else { return }
        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload, kLSQuarantineAgentNameKey as String: "Kelp"
        ]
        props[kLSQuarantineDataURLKey as String] = source
        props[kLSQuarantineOriginURLKey as String] = page
        var values = URLResourceValues(), file = to
        values.quarantineProperties = props
        do { try file.setResourceValues(values) } catch {
            failed(to.lastPathComponent, error)
            return
        }
        if agentAnswers {
            noteDownload("\(to.path) (done, \(download.progress.completedUnitCount) bytes)")
            return
        }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: to.path)
        Banner.show(
            String(localized: "Downloaded \(to.lastPathComponent)"),
            action: (
                String(localized: "Show in Finder"),
                {
                    NSWorkspace.shared.activateFileViewerSelecting([to])
                }
            ))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDecided = nil
        let name =
            downloading.removeValue(forKey: ObjectIdentifier(download))?.to.lastPathComponent
            ?? String(localized: "a file")
        failed(name, error)
    }

    private func failed(_ name: String, _ error: Error) {
        if agentAnswers {
            noteDownload("\(name) failed: \(error.localizedDescription)")
            return
        }
        Banner.show(String(localized: "Couldn't download \(name): \(error.localizedDescription)"), style: .error)
    }

    /// A download the agent's page made: in its console, and in the answer of the action that started it.
    private func noteDownload(_ line: String) {
        noteLog("[download] " + line)
        if let drive { AgentDrive.add(line, to: &drive.downloads) }
    }

    /// `name` in `dir`, or as Safari names the next one when it's taken: `report-2.pdf`, `report-3.pdf`…
    nonisolated static func free(_ name: String, in dir: URL, taken: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name), number = 1
        while taken(url) {
            number += 1
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)")
        }
        return url
    }
}
