import AppKit
import Core
import DesignKit
import KelpKit

/// The project's GitHub, GitLab or Bitbucket: its pages in the browser, and gh / glab set up when they're missing.
@MainActor
enum Forge {
    /// A button's title, what the button is for, the command it runs, and what is wrong in a few words (the title of
    /// the panel's empty state).
    typealias Setup = (title: String, note: String, command: String, state: String)

    /// When gh or glab is missing or signed out (the error says which), returns what fixes it. Returns nil for any
    /// other error (no remote, the network, a failing API).
    static func setup(for error: String) -> Setup? {
        switch FixRecipes.fix(for: error)?.command {
        case "brew install gh"?: install("gh")
        case "brew install glab"?: install("glab")
        case "gh auth login"?: signIn("gh")
        case "glab auth login"?: signIn("glab")
        default: nil
        }
    }

    /// No remote on GitHub isn't an error. This returns an empty state that says so in the person's language, and what
    /// changes it.
    static func noRemote(_ message: String?) -> (title: String, text: String)? {
        guard message == GitHub.noRemote else { return nil }
        return (
            String(localized: "No GitHub Remote"),
            String(
                localized: "Pull requests, issues and CI runs show here once this project's git has a remote on GitHub."
            )
        )
    }

    /// The setup that installs `cli`, which is gh or glab.
    static func install(_ cli: String) -> Setup {
        let site = cli == "glab" ? "GitLab" : "GitHub"
        return (
            String(localized: "Install \(site) CLI"),
            String(localized: "Kelp reaches \(site) through its CLI, \(cli). Install it with Homebrew and sign in."),
            "brew install \(cli) && \(cli) auth login", String(localized: "\(site) CLI Isn’t Installed")
        )
    }
    static func signIn(_ cli: String) -> Setup {
        let site = cli == "glab" ? "GitLab" : "GitHub"
        return (
            String(localized: "Sign In to \(site)"), String(localized: "The \(site) CLI (\(cli)) isn't signed in."),
            "\(cli) auth login", String(localized: "\(site) CLI Isn’t Signed In")
        )
    }

    /// Runs the setup in a terminal tab, where the login asks its questions; Settings runs it too. When there's no
    /// window to run it in, the command is copied.
    static func run(_ setup: Setup, in app: AppModel) {
        guard let starter = app.workbench.starter else {
            copyText(setup.command)
            Banner.show(String(localized: "Copied “\(setup.command)”: run it in Terminal"))
            return
        }
        starter.run(command: setup.command, title: setup.title)
        app.workbench.bringToFront()
    }

    /// Opens the page in the default browser, where the user is signed in to the site.
    static func open(_ url: String) { if let page = webPage(url) { PreviewLinks.openOutside(page) } }

    /// Opens only a web page. The URL comes from a forge's or a tracker's API, and a self-hosted one could hand over a
    /// file or another app's URL scheme, which `NSWorkspace` would run.
    static func webPage(_ url: String) -> URL? {
        guard let page = URL(string: url), ["http", "https"].contains(page.scheme?.lowercased()) else { return nil }
        return page
    }

    /// Opens one of the workspace's pages (for the palette's commands), or shows a banner when origin isn't on a site.
    static func open(_ app: AppModel, _ page: KeyPath<GitWebPages.Pages, String>) {
        guard let worktree = app.workbench.workspaceId else {
            NSSound.beep()
            return
        }
        Task {
            // On failure the banner says why.
            guard let pages = await app.call(GitWebPages(worktreeId: worktree)) else { return }
            guard let pages else {
                Banner.show(
                    String(localized: "This project's origin isn't on GitHub, GitLab or Bitbucket."), style: .error)
                return
            }
            open(pages[keyPath: page])
        }
    }

    /// The menu of the repository, CI, pull / merge requests and issues, named the site's way.
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

extension Forge {
    /// True for a failure that a later read may not have (the network, a timeout), so the rows read before stay on
    /// show under it. A tool to set up or a missing remote is a state, which takes the list's place.
    static func passing(_ error: String) -> Bool { setup(for: error) == nil && noRemote(error) == nil }
}

extension EmptyStateView {
    /// Shows a forge's `error` instead of the list: gh or glab to set up (on `setupButton`, then Check Again), no
    /// GitHub remote, or `failed` with `hint` or the error's words. Returns the setup, for the button to run.
    func showForge(
        _ error: String, failed: String, hint: String? = nil, setupButton: NSButton, checkAgain: NSButton
    ) -> Forge.Setup? {
        let setup = Forge.setup(for: error)
        setupButton.isHidden = setup == nil
        if let setup {
            setupButton.title = setup.title
            setupButton.toolTip = setup.command
            show(
                setup.state, symbol: "terminal",
                text: setup.note + " " + String(localized: "It runs in a terminal tab; then Try Again."),
                buttons: [setupButton, checkAgain])
        } else if let quiet = Forge.noRemote(error) {
            show(quiet.title, symbol: "network", text: quiet.text, buttons: [checkAgain])
        } else {
            showError(failed, text: hint ?? error, buttons: [checkAgain])
        }
        return setup
    }
}
