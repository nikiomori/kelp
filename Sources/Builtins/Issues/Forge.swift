import AppKit
import Core
import DesignKit
import KelpKit

/// The project's GitHub / GitLab / Bitbucket: its pages in the browser, and gh / glab set up when they're missing.
@MainActor
enum Forge {
    /// A button's title, what it's for, and the command it runs.
    typealias Setup = (title: String, note: String, command: String)

    /// gh or glab missing or signed out (the error says which), and what fixes it; nil for anything else (no remote,
    /// the network, a failing API).
    static func setup(for error: String) -> Setup? {
        switch FixRecipes.fix(for: error)?.command {
        case "brew install gh"?: install("gh")
        case "brew install glab"?: install("glab")
        case "gh auth login"?: signIn("gh")
        case "glab auth login"?: signIn("glab")
        default: nil
        }
    }

    /// No remote on GitHub isn't an error: an empty state that says so in the person's language, and what changes it.
    static func noRemote(_ message: String?) -> (title: String, text: String)? {
        guard message == GitHub.noRemote else { return nil }
        return (
            String(localized: "No GitHub Remote"),
            String(
                localized: "Pull requests, issues and CI runs show here once this project's git has a remote on GitHub."
            )
        )
    }

    /// `cli`: gh or glab.
    static func install(_ cli: String) -> Setup {
        let site = cli == "glab" ? "GitLab" : "GitHub"
        return (
            String(localized: "Install \(site) CLI"),
            String(localized: "Kelp reaches \(site) through its CLI, \(cli). Install it with Homebrew and sign in."),
            "brew install \(cli) && \(cli) auth login"
        )
    }
    static func signIn(_ cli: String) -> Setup {
        let site = cli == "glab" ? "GitLab" : "GitHub"
        return (
            String(localized: "Sign In to \(site)"), String(localized: "The \(site) CLI (\(cli)) isn't signed in."),
            "\(cli) auth login"
        )
    }

    /// In a terminal tab, where the login asks its questions; from Settings too. No window to run it in: the command is copied.
    static func run(_ setup: Setup, in app: AppModel) {
        guard let starter = app.workbench.starter else {
            copyText(setup.command)
            Banner.show(String(localized: "Copied “\(setup.command)”: run it in Terminal"))
            return
        }
        starter.run(command: setup.command, title: setup.title)
        app.workbench.bringToFront()
    }

    /// In the default browser, where the user is signed in to the site.
    static func open(_ url: String) { if let page = webPage(url) { PreviewLinks.openOutside(page) } }

    /// Only a web page: the URL comes from a forge's or tracker's API, and a self-hosted one could hand over a file or
    /// another app's scheme, which `NSWorkspace` would run.
    static func webPage(_ url: String) -> URL? {
        guard let page = URL(string: url), ["http", "https"].contains(page.scheme?.lowercased()) else { return nil }
        return page
    }

    /// One of the workspace's pages (the palette's commands); a banner when origin isn't on a site.
    static func open(_ app: AppModel, _ page: KeyPath<GitWebPages.Pages, String>) {
        guard let worktree = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        Task {
            guard let pages = await app.call(GitWebPages(worktreeId: worktree)) else { return }   // the banner says why
            guard let pages else {
                Banner.show(
                    String(localized: "This project's origin isn't on GitHub, GitLab or Bitbucket."), style: .error)
                return
            }
            open(pages[keyPath: page])
        }
    }

    /// Repository, CI, pull / merge requests and issues, named the site's way.
    static func menu(_ pages: GitWebPages.Pages) -> NSMenu {
        let menu = NSMenu()
        let site = ["gitlab": "GitLab", "bitbucket": "Bitbucket"][pages.forge] ?? "GitHub"
        menu.add(String(localized: "Repository on \(site)"), symbol: "book.closed") { open(pages.repo) }
        menu.add(
            pages.forge == "github" ? String(localized: "Actions") : String(localized: "Pipelines"),
            symbol: "checkmark.seal"
        ) { open(pages.ci) }
        menu.add(
            pages.forge == "gitlab" ? String(localized: "Merge Requests") : String(localized: "Pull Requests"),
            symbol: "arrow.triangle.pull"
        ) { open(pages.pulls) }
        menu.add(String(localized: "Issues"), symbol: "smallcircle.filled.circle") { open(pages.issues) }
        return menu
    }
}

extension EmptyStateView {
    /// A forge's `error` instead of the list: gh or glab to set up (on `setupButton`, then Check Again), no GitHub
    /// remote, or `failed` with `hint` or the error's words. The setup, for the button to run.
    func showForge(
        _ error: String, failed: String, hint: String? = nil, setupButton: NSButton, checkAgain: NSButton
    ) -> Forge.Setup? {
        let setup = Forge.setup(for: error)
        setupButton.isHidden = setup == nil
        if let setup {
            setupButton.title = setup.title
            setupButton.toolTip = setup.command
            show(
                setup.note, symbol: "terminal", text: String(localized: "It runs in a terminal tab; then Check Again."),
                buttons: [setupButton, checkAgain])
        } else if let quiet = Forge.noRemote(error) {
            show(quiet.title, symbol: "network", text: quiet.text, buttons: [checkAgain])
        } else {
            showError(failed, text: hint ?? error, buttons: [checkAgain])
        }
        return setup
    }
}
