import AppKit
import WebKit
import KelpKit

/// Files a page hands over instead of showing: a link with `download`, an attachment, a type WebKit can't show. Without
/// this they were cancelled without a word. The user's go to ~/Downloads as Safari's do (a new name beside one already
/// there, the Downloads stack bounces, a banner shows it in Finder); a page an agent drives keeps its own in a folder of
/// Kelp's in the temporary directory, said in the action's answer and console. Each is marked as downloaded from the
/// web (quarantine), so Gatekeeper looks at it before it opens.
extension BrowserTab: WKDownloadDelegate {
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (a.shouldPerformDownload ? .download : .allow, preferences)
    }

    /// What the page answered is a file to keep: not a type WebKit shows, or sent as an attachment.
    static func downloads(_ r: WKNavigationResponse) -> Bool {
        let disposition = (r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return !r.canShowMIMEType || disposition.lowercased().hasPrefix("attachment")
    }

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String) async -> URL? {
        let dir = agentAnswers ? FileManager.default.temporaryDirectory.appendingPathComponent("kelp-downloads", isDirectory: true)
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            failed(name, error); return nil
        }
        let safe = (name as NSString).lastPathComponent.isEmpty ? "download" : (name as NSString).lastPathComponent
        // Taken: on disk, or the path of a download still coming (two "report.pdf" at once).
        let coming = Set(downloading.values.map(\.0))
        let to = Self.free(safe, in: dir) { coming.contains($0) || FileManager.default.fileExists(atPath: $0.path) }
        downloading[ObjectIdentifier(d)] = (to, r.url, web.url)
        if agentAnswers { noteDownload("\(safe) → \(to.path) (started)") }
        return to
    }

    func downloadDidFinish(_ d: WKDownload) {
        guard let (to, source, page) = downloading.removeValue(forKey: ObjectIdentifier(d)) else { return }
        var props: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload, kLSQuarantineAgentNameKey as String: "Kelp"]
        props[kLSQuarantineDataURLKey as String] = source
        props[kLSQuarantineOriginURLKey as String] = page
        var values = URLResourceValues(), file = to
        values.quarantineProperties = props
        do { try file.setResourceValues(values) } catch { failed(to.lastPathComponent, error); return }
        if agentAnswers {
            noteDownload("\(to.path) (done, \(d.progress.completedUnitCount) bytes)")
            return
        }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: to.path)
        Banner.show(String(localized: "Downloaded \(to.lastPathComponent)"), action: (String(localized: "Show in Finder"), {
            NSWorkspace.shared.activateFileViewerSelecting([to])
        }))
    }

    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) {
        let name = downloading.removeValue(forKey: ObjectIdentifier(d))?.to.lastPathComponent ?? String(localized: "a file")
        failed(name, e)
    }

    private func failed(_ name: String, _ e: Error) {
        if agentAnswers { noteDownload("\(name) failed: \(e.localizedDescription)"); return }
        Banner.show(String(localized: "Couldn't download \(name): \(e.localizedDescription)"), style: .error)
    }

    /// A download the agent's page made: in its console, and in the answer of the action that started it.
    private func noteDownload(_ s: String) {
        noteLog("[download] " + s)
        downloads.append(s)
    }

    /// `name` in `dir`, or as Safari names the next one when it's taken: `report-2.pdf`, `report-3.pdf`…
    nonisolated static func free(_ name: String, in dir: URL, taken: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var u = dir.appendingPathComponent(name), n = 1
        while taken(u) {
            n += 1
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
        }
        return u
    }
}
