import Foundation
import UniformTypeIdentifiers
import WebKit

/// An extension's own files, served to its web view with a policy a file URL can't carry. A page may show other people's
/// text (an issue's title) and `kelp.exec` runs commands: markup that text slips in (`<img onerror=…>`) runs no script.
/// The page's own scripts, inline or from a site, still do. `kelp-ext://page/<path in the folder>`.
@MainActor
final class ExtPages: NSObject, WKURLSchemeHandler {
    static let scheme = "kelp-ext"
    static let policy = "script-src-attr 'none'; object-src 'none'"
    let folder: URL
    init(folder: URL) { self.folder = folder }

    /// The address of `file`, one in the folder.
    func url(of file: URL) -> URL? {
        let base = folder.resolvingSymlinksInPath().path, path = file.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "page"
        components.path = String(path.dropFirst(base.count))
        return components.url
    }

    /// The folder's file an address names; nil for one outside it (`..`, a link out).
    func file(_ u: URL) -> URL? {
        guard u.scheme == Self.scheme else { return nil }
        let resolved = folder.appendingPathComponent(u.path).resolvingSymlinksInPath()
        return resolved.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") ? resolved : nil
    }

    func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let found = file(url) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let data: Data
        do { data = try Data(contentsOf: found) } catch { return task.didFailWithError(error) }
        let type = UTType(filenameExtension: found.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": type, "Content-Security-Policy": Self.policy])
        else {
            return task.didFailWithError(URLError(.cannotParseResponse))
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) {}
}
