import AppKit
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

/// Handles the files a page hands over instead of showing: a link with `download`, an attachment, a type WebKit can't
/// show. Without this, they were cancelled without a word. Files from the user's pages go to ~/Downloads as Safari's
/// do, with a new name when one is already there, a bounce of the Downloads stack, and a banner that shows the file in
/// Finder. A page an agent drives keeps its files in a Kelp folder in the temporary directory, named in the action's
/// answer and the console. Each file is marked as downloaded from the web (quarantine), so Gatekeeper looks at it
/// before it opens.
extension BrowserTab: WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences)
        async
        -> (WKNavigationActionPolicy, WKWebpagePreferences)
    {
        if let url = action.request.url, leavesSharedSite(url, mainFrame: action.targetFrame?.isMainFrame != false) {
            noteLog("[blocked] \(url.absoluteString): another site than the one the user let the agent use")
            return (.cancel, preferences)
        }
        // For mailto:, tel: or an app's own scheme, WebKit would show its error page over the page the link was on.
        if let url = action.request.url, !Self.inPage.contains(url.scheme?.lowercased() ?? "") {
            if agentAnswers {
                noteLog("[blocked] \(url.absoluteString): not a web page")
            } else if action.navigationType == .linkActivated {
                PreviewLinks.openOutside(url)   // a mailto: link opens in Mail; other schemes get a banner
            }
            return (.cancel, preferences)
        }
        if action.shouldPerformDownload { downloadDecided = Date() }
        return (action.shouldPerformDownload ? .download : .allow, preferences)
    }

    /// Whether `url` leaves the one site the user let the agent use in their logged-in browser (`open --shared`). While
    /// the agent drives the page, the page stays on that site, and another site must be asked for again.
    func leavesSharedSite(_ url: URL, mainFrame: Bool) -> Bool {
        guard agentAnswers, !agent, mainFrame, url.scheme != "about",
            let allowed = URL(string: start).flatMap(PageOrigin.of)
        else { return false }
        return PageOrigin.of(url) != allowed
    }

    /// The schemes a page loads itself. Any other scheme is a link out of the page.
    private static let inPage: Set<String> = ["http", "https", "about", "file", "data", "blob", "javascript"]

    /// The sites the user allowed to download files since Kelp started.
    static var downloadsAllowed: Set<String> = []

    private static func allowDownloads(from host: String) async -> Bool {
        await confirm(
            String(localized: "Allow downloads from \(host)?"),
            detail: String(localized: "Its files go to your Downloads folder."), action: String(localized: "Allow"),
            cancel: String(localized: "Don’t Allow"))
    }

    /// Whether the page's response is a file to keep: a type WebKit can't show, or one sent as an attachment.
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
        // The user's pages ask once per site, as Safari does, so a page can't fill ~/Downloads unasked.
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
        // A name is taken when it's on disk, or is the path of a download still coming (two "report.pdf" at once).
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
        Banner.show(String(localized: "Couldn’t download \(name): \(error.localizedDescription)"), style: .error)
    }

    /// Notes a download the agent's page made, in the page's console and in the answer of the action that started it.
    private func noteDownload(_ line: String) {
        noteLog("[download] " + line)
        if let drive { AgentDrive.add(line, to: &drive.downloads) }
    }

    /// Returns `name` in `dir`, or, when that is taken, the next name as Safari picks it: `report-2.pdf`,
    /// `report-3.pdf`…
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
