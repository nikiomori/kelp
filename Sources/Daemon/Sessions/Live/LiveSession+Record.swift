import Core
import Foundation

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

    /// Records a hook's `cwd`, where the agent works now. Returns the record when that changed.
    func workIn(_ dir: String) -> Session? {
        func real(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let workDir = real(dir) == real(snapshot.cwd) ? nil : dir   // the folder it started in never changes
        return state.withLock { st in
            guard workDir != st.record.workDir else { return nil }
            st.record.workDir = workDir
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
