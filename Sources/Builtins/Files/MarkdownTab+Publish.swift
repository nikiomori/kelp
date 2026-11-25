import AppKit
import Core
import DesignKit
import KelpKit

/// A page put on the web by its agent, with the agent's own tools (Kelp signs in nowhere): ⋯ › Publish asks it to,
/// and it writes the link into `published.txt` beside the page. With a link, ⋯ copies and opens it, asks for the
/// published page to be brought up to date, and brings the comments people left on it in as marks to send.
extension MarkdownTab {
    /// The links of pages, by page, as last read from their `published.txt`.
    private static var links: [String: String] = [:]
    var publishedLink: String? { Self.links[url.path] }
    private var linkFile: String { url.deletingLastPathComponent().appendingPathComponent("published.txt").path }

    /// Reads the page's link again: its agent may have written it since.
    func loadPublished() async {
        let text = await app.quiet(FilesRead(path: linkFile))?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.links[url.path] = text.flatMap { $0.hasPrefix("https://") && !$0.contains(" ") ? $0 : nil }
    }

    /// ⋯'s Publish section.
    func publishItems(_ menu: NSMenu) {
        let page = Artifacts.projectPath(url.path), file = Artifacts.projectPath(linkFile)
        guard let link = publishedLink else {
            menu.add(String(localized: "Publish")) { [weak self] in self?.send(Self.publish(page, link: file)) }
            return
        }
        menu.add(String(localized: "Copy Link")) { copyText(link) }
        menu.add(String(localized: "Open Link")) {
            if let to = URL(string: link) { PreviewLinks.openOutside(to) }
        }
        menu.add(String(localized: "Update the Published Page")) { [weak self] in
            self?.send(Self.republish(page, link: link))
        }
        menu.add(String(localized: "Bring In Comments as Marks")) { [weak self] in
            self?.send(Self.comments(page, link: link, canvas: self?.page == .canvas || self?.page == .motion))
        }
    }

    static func publish(_ page: String, link file: String) -> String {
        "Publish \(page) as one page with your own artifact tools (the page as it shows: a canvas's boards all on it), "
            + "private to the user. Then write its link alone into \(file). Say if you have no tools to publish with."
    }

    static func republish(_ page: String, link: String) -> String {
        "Publish \(page) again as a new version of the page at \(link) (the same link), with your own artifact tools."
    }

    static func comments(_ page: String, link: String, canvas: Bool) -> String {
        let name = (page as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? page
        let put =
            canvas
            ? "add it as `kelp artifact ask \(name) <data-id of the element it is on, else the board's first> "
                + "\"<who>: <comment>\"`"
            : "suggest it with `kelp artifact suggest \(name) \"<who>: <comment>\"` (three at most)"
        return "Read the open comments on \(link) with your own artifact tools. For each, \(put); answer its thread "
            + "\"Taken into Kelp\" and leave it open. Change nothing on the page."
    }
}
