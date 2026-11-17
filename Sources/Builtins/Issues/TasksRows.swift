import Core
import KelpKit

/// What the Tasks panel lists: the rows of a source (PRs, issues, a tracker's tasks, a board's items), the sources in
/// the menu's order with what each says when it is empty or can't be read, and the lines the table shows.
extension TasksViewController {
    /// What the selected source lists.
    enum Row {
        case pr(GitHub.PullRequest), issue(GitHub.Issue), linear(LinearIssue), jira(JiraIssue), item(GitHub.ProjectItem)
        var url: String? {
            switch self {
            case .pr(let pr): pr.url
            case .issue(let issue): issue.url
            case .linear(let issue): issue.url
            case .jira(let issue): issue.url
            case .item(let item): item.url
            }
        }
    }
    /// What the source menu lists, in its order.
    enum Source: Int, CaseIterable {
        case pulls, issues, linear, jira, projects

        var title: String {
            switch self {
            case .pulls: String(localized: "Pull Requests")
            case .issues: String(localized: "Issues")
            case .linear: String(localized: "Linear")
            case .jira: String(localized: "Jira")
            case .projects: String(localized: "Projects")
            }
        }
        /// The filter menu's own items. Linear adds its teams to them, and Projects its boards once they're read.
        var filters: [String] {
            switch self {
            case .pulls: [String(localized: "Open"), String(localized: "Recently Closed")]
            case .issues: [String(localized: "All open"), String(localized: "Assigned to me")]
            case .linear: [String(localized: "My issues")]
            case .jira: [String(localized: "My open issues"), String(localized: "Custom JQL…")]
            case .projects: [String(localized: "Loading projects…")]
            }
        }
        /// Whether the source is read from the project's forge (gh or glab), so that a missing remote or CLI is what an
        /// error means. Linear and Jira need neither.
        var needsRemote: Bool { self != .linear && self != .jira }
        /// What to do when the source can't be read and gh or glab has no fix to offer; nil shows the error's own
        /// words.
        var connectHint: String? {
            switch self {
            case .linear: String(localized: "Connect Linear in Settings › Integrations")
            case .jira: String(localized: "Connect Jira in Settings › Integrations")
            case .projects: String(localized: "Projects need `gh auth refresh -s read:project`")
            case .pulls, .issues: nil
            }
        }
        /// What the list says when it's empty with no filter. Nil means "Nothing here", because no filter narrows it.
        var none: String? {
            switch self {
            case .pulls: String(localized: "No Open Pull Requests")
            case .issues: String(localized: "No Open Issues")
            case .linear, .jira, .projects: nil
            }
        }
    }
    /// What the table shows: the rows, with headings over the parts of a list of PRs.
    enum Line {
        case heading(String), row(Row)
    }
    /// A PR's or issue's number, which identifies it across a refresh.
    static func number(_ row: Row) -> Int? {
        switch row {
        case .pr(let pr): pr.number
        case .issue(let issue): issue.number
        case .linear, .jira, .item: nil
        }
    }
}
