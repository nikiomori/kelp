import BuiltinActivity
import BuiltinAgents
import BuiltinBrowser
import BuiltinDatabases
import BuiltinFiles
import BuiltinGit
import BuiltinIssues
import BuiltinMachines
import BuiltinRoutines
import BuiltinRun
import BuiltinServers
import KelpKit

extension Builtins {
    /// Every built-in extension, in the order their contributions are taken.
    static let all: [Builtin] = [
        workbench, agents, appearance, files, run, git, browser, issues, activity, routines, servers, machines,
        databases
    ]
}
