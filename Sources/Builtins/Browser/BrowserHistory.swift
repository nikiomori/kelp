import Foundation

/// The pages the user visited in Kelp's browser tabs (an agent's pages aren't kept), newest first, for the address
/// bar's completion. Per Mac, in UserDefaults. Limit: the last 500 addresses, matched from their start.
enum BrowserHistory {
    static let key = "browser.history"
    @MainActor static var urls: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    @MainActor static func visited(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        let text = url.absoluteString
        UserDefaults.standard.set(Array(([text] + urls.filter { $0 != text }).prefix(500)), forKey: key)
    }

    /// What completes `typed`: the rest of the newest address that starts with it, as the bar shows it (no scheme or
    /// www. unless typed). While no "/" is typed, only up to the site: "git" → "hub.com", as Safari does.
    static func completion(_ typed: String, in urls: [String]) -> String? {
        let want = typed.lowercased()
        guard want.count >= 2, !want.contains(" ") else { return nil }
        for url in urls {
            var shown = want.contains("://") ? url : bare(url)
            guard shown.lowercased().hasPrefix(want) else { continue }
            let path = shown.range(of: "://")?.upperBound ?? shown.startIndex
            if !bare(want).contains("/"), let slash = shown[path...].firstIndex(of: "/") {
                shown = String(shown[..<slash])
            }
            return shown.count > typed.count ? String(shown.dropFirst(typed.count)) : nil
        }
        return nil
    }
    @MainActor static func completion(_ typed: String) -> String? { completion(typed, in: urls) }

    /// `text` with the scheme it was visited with, when it's an address completed from the history without one (a site
    /// served over http stays http); otherwise `text` as typed.
    static func address(for text: String, in urls: [String]) -> String {
        guard !text.contains("://"),
            let url = urls.first(where: { bare($0) == text || bare($0).hasPrefix(text + "/") }),
            let scheme = url.range(of: "://")
        else { return text }
        let www = url[scheme.upperBound...].hasPrefix("www.") ? "www." : ""
        return url[..<scheme.upperBound] + www + text
    }
    @MainActor static func address(for text: String) -> String { address(for: text, in: urls) }

    static func bare(_ url: String) -> String {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if rest.hasPrefix("www.") { rest = rest.dropFirst(4) }
        return String(rest)
    }
}
