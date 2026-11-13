import AppKit
import Core
import DesignKit
import KelpKit
import Markdown
import WebKit
import WorkbenchKit

/// "pr:<project>/<n>", "issue:<project>/<n>": a pull request or an issue in a tab of its own, with the room its
/// description and conversation need; its bar holds the one thing to do next, the rest under ⋯.
@MainActor @Observable
final class ForgeItemTab: KelpKit.TabContent {   // not SwiftUI's
    enum Kind: String { case pr, issue }

    @ObservationIgnored let uri: String
    @ObservationIgnored let view: NSView
    private(set) var title: String
    @ObservationIgnored let kind: Kind
    @ObservationIgnored let repoId: String
    @ObservationIgnored let number: Int
    @ObservationIgnored let app: AppModel
    @ObservationIgnored private let web = WKWebView()
    @ObservationIgnored private let links: PreviewLinks
    @ObservationIgnored private let barSlot = NSView()
    @ObservationIgnored private let empty = EmptyStateView()
    @ObservationIgnored private let loading = LoadingView()
    @ObservationIgnored var prView: GitHub.PRView?
    @ObservationIgnored var issueView: GitHub.IssueView?
    @ObservationIgnored var viewer: String?

    var icon: NSImage? { .symbol(kind == .pr ? "arrow.triangle.pull" : "smallcircle.filled.circle") }

    static func uri(_ kind: Kind, repoId: String, number: Int) -> String { "\(kind.rawValue):\(repoId)/\(number)" }
    static func parse(_ uri: String) -> (kind: Kind, repoId: String, number: Int)? {
        guard let colon = uri.firstIndex(of: ":"), let kind = Kind(rawValue: String(uri[..<colon])) else { return nil }
        let rest = uri[uri.index(after: colon)...]
        guard let slash = rest.lastIndex(of: "/"), let number = Int(rest[rest.index(after: slash)...]) else {
            return nil
        }
        return (kind, String(rest[..<slash]), number)
    }
    /// "#49" until it's read.
    static func title(_ uri: String) -> String { parse(uri).map { "#\($0.number)" } ?? uri }

    init?(uri: String, app: AppModel) {
        guard let (kind, repoId, number) = Self.parse(uri) else { return nil }
        self.uri = uri
        self.kind = kind
        self.repoId = repoId
        self.number = number
        self.app = app
        title = Self.title(uri)
        links = PreviewLinks(app: app)
        web.navigationDelegate = links
        web.setValue(false, forKey: "drawsBackground")
        view = stacked(barSlot, web)
        empty.place(in: view, under: barSlot)
        loading.place(in: view, under: barSlot)
        reload()
    }

    func focus() { view.window?.makeFirstResponder(web) }

    /// Read it again: on opening, after an action, from ⋯.
    func reload() {
        let slow = whileSlow { [weak self] in self?.loading.show(String(localized: "Loading…")) }
        Task { [weak self] in
            guard let self else { return }
            viewer = await Viewer.get(app)
            switch kind {
            case .pr:
                let read = await app.tryCall(GitHubPRView(repoId: repoId, pr: number))
                slow.cancel()
                guard let view = read.value else { return failed(read.error) }
                prView = view
                title = "#\(number) \(view.pr.title)"
                show(ForgePage.pr(view, checks: nil, block: PRWork.mergeBlock(view.pr)))
                let checks = await app.quiet(GitHubChecks(repoId: repoId, pr: number))   // the page says none were read
                show(ForgePage.pr(view, checks: checks ?? [], block: PRWork.mergeBlock(view.pr)))
            case .issue:
                let read = await app.tryCall(GitHubIssueView(repoId: repoId, issue: number))
                slow.cancel()
                guard let view = read.value else { return failed(read.error) }
                issueView = view
                title = "#\(number) \(view.issue.title)"
                show(ForgePage.issue(view, working: issueFolder?.branch))
            }
        }
    }

    private func show(_ body: String) {
        loading.show(nil)
        empty.show(nil)
        web.isHidden = false
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        links.load(MarkdownHTML.page(body: body, baseURL: nil, dark: dark), baseURL: nil, in: web)
        showBar()
    }

    private func failed(_ error: String?) {
        loading.show(nil)
        web.isHidden = true
        let open = ClosureButton(title: String(localized: "Open in Browser")) { [weak self] in self?.openInBrowser() }
        let again = ClosureButton(title: String(localized: "Check Again")) { [weak self] in self?.reload() }
        empty.showError(String(localized: "Couldn't read #\(number)"), text: error ?? "", buttons: [again, open])
        showBar()
    }

    private func showBar() {
        barSlot.subviews.forEach { $0.removeFromSuperview() }
        barSlot.pin(kind == .pr ? prBar() : issueBar())
    }

    /// The forge's page of it, in the default browser.
    func openInBrowser() {
        if let url = prView?.pr.url ?? issueView?.issue.url { Forge.open(url) }
    }
    var webURL: String? { prView?.pr.url ?? issueView?.issue.url }

    /// The group already working on this issue (started from it, on its own branch).
    var issueFolder: Worktree? {
        app.worktrees.first { $0.repoId == repoId && $0.issue == "#\(number)" && !$0.archived }
    }
}
