import Foundation

/// Errors Kelp recognizes, with the exact command that fixes them: an error banner offers "Copy Fix" instead of
/// leaving you to search. `blocking`: git itself doesn't work (Xcode's license, no developer tools), so nothing
/// git-related will until it's fixed; that banner stays until it's closed.
public enum FixRecipes {
    public struct Fix: Equatable, Sendable {
        public var command: String
        public var blocking = false
    }

    static let known: [(match: [String], fix: Fix)] = [
        (
            ["agreed to the Xcode license", "Xcode license agreement"],
            Fix(command: "sudo xcodebuild -license accept", blocking: true)
        ),
        (
            ["invalid active developer path", "No developer tools were found", "xcrun: error"],
            Fix(command: "xcode-select --install", blocking: true)
        ),
        (
            ["gh CLI not found", "gh: command not found", "Install the GitHub CLI", "Install GitHub CLI"],
            Fix(command: "brew install gh")
        ),
        (["glab CLI not found", "glab: command not found"], Fix(command: "brew install glab")),
        (["gh auth login", "not logged into any GitHub hosts", "authentication token"], Fix(command: "gh auth login")),
        (["glab auth login", "401 Unauthorized"], Fix(command: "glab auth login")),
        (
            ["Please tell me who you are", "Author identity unknown", "unable to auto-detect email address"],
            Fix(
                command:
                    #"git config --global user.name "Your Name" && git config --global user.email "you@example.com""#)
        ),
        (["no upstream branch"], Fix(command: "git push -u origin HEAD")),
        (
            ["Updates were rejected because the remote contains work", "fetch first", "non-fast-forward"],
            Fix(command: "git pull --rebase")
        ),
        (["Permission denied (publickey)"], Fix(command: "ssh -T git@github.com"))
    ]

    public static func fix(for error: String) -> Fix? {
        known.first { k in k.match.contains { error.localizedCaseInsensitiveContains($0) } }?.fix
    }
}
