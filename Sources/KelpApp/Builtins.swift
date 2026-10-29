import KelpKit
import BuiltinAgents
import BuiltinFiles
import BuiltinGit
import BuiltinBrowser
import BuiltinIssues
import BuiltinActivity
import BuiltinRoutines

extension Builtins {
    /// Every built-in extension, in the order their contributions are taken.
    static let all: [Builtin] = [workbench, agents, appearance, files, git, browser, issues, activity, routines]
}
