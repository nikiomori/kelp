import Core
import Foundation
import GitKit

extension LiveSession {
    var commands: [AgentCommand] { state.withLock { $0.commands } }
    /// `kelp why`: the status, where it came from, and when the agent last spoke up by itself.
    var statusWhy: String {
        state.withLock { st in
            let heard =
                st.lastHookAt == .distantPast ? "" : ", last heard \(Int(-st.lastHookAt.timeIntervalSinceNow)) s ago"
            return "\(st.detector.status.rawValue) (\(st.detector.source))\(heard)"
        }
    }
    var commandChanges: Int { state.withLock { $0.commandChanges } }
    /// The file its tools changed last, and how many edits so far.
    var lastEdit: (path: String?, count: Int) { state.withLock { ($0.lastEdit, $0.edits) } }
    func edited(_ path: String) {
        state.withLock {
            $0.lastEdit = path
            $0.edits += 1
        }
    }

    /// Records the page the agent works on (nil when its turn ends). Returns the record when that changed: a second
    /// step on the same page in the same way only moves its time, which nobody shows.
    func works(on page: SessionPage?) -> Session? {
        state.withLock { st in
            let same = st.record.page?.target == page?.target && st.record.page?.doing == page?.doing
            st.record.page = page
            return same ? nil : st.record
        }
    }

    /// Records a hook's `cwd`, where the agent works now, and the worktree of its own that is in (`branchFolder`, kept
    /// when it goes back). Returns the record when either changed.
    func workIn(_ dir: String) -> Session? {
        func real(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let workDir = real(dir) == real(snapshot.cwd) ? nil : dir   // the folder it started in never changes
        let branch = workDir == nil ? nil : Git.linkedWorktree(containing: dir, besides: snapshot.cwd)
        return state.withLock { st in
            guard workDir != st.record.workDir || branch.map({ $0 != st.record.branchFolder }) == true else {
                return nil
            }
            st.record.workDir = workDir
            if let branch { st.record.branchFolder = branch }
            return st.record
        }
    }

    /// Applies `body` and returns whether that changed the record; a record that didn't change needs no save.
    func change(_ body: @Sendable (inout Session) -> Void) -> Bool {
        state.withLock { st in
            let before = st.record
            body(&st.record)
            return st.record != before
        }
    }
}
