import Agents
import Core
import Foundation

extension Conversations {
    /// Older session records may only name their current thread in a terminal hook report. The search widens
    /// from the log's last 64 KB to all of it, because a long turn can print far more than that after the report.
    func lastCodexReport(of session: Session) -> UUID? {
        guard UUID(uuidString: session.id) != nil else { return nil }
        let log = history.appendingPathComponent(session.id + ".log")
        var bytes = 64 << 10
        while let tail = Data(tail: bytes, of: log) {
            var carry = ""
            for message in ProgramStatus.scan(String(decoding: tail, as: UTF8.self), carry: &carry).reversed() {
                if case .report(let report) = message, report.id == nil, let conv = report.conv {
                    return UUID(uuidString: conv)
                }
            }
            guard tail.count == bytes else { return nil }   // that was the whole log
            bytes *= 8
        }
        return nil
    }

    /// A hook's rollout names the thread currently open, even after an in-session resume. Use its basename under
    /// Codex's sessions folder, so a hook cannot redirect the read to an arbitrary file on the host.
    static func codexTailScript(
        _ session: Session, thread: UUID?, transcript: String?, then: String? = nil
    ) -> String? {
        let name = transcript.map { ($0 as NSString).lastPathComponent }
        let filename = /rollout-([0-9]{4})-([0-9]{2})-([0-9]{2})T[0-9]{2}-[0-9]{2}-[0-9]{2}-([a-fA-F0-9-]{36})\.jsonl/
        let rollout = name?.wholeMatch(of: filename)
        let hookID = rollout.flatMap { UUID(uuidString: String($0.4)) }
        let resume = resumedThread(session.argv)
        let observed = thread ?? hookID
        let pane = session.tmux.flatMap { Tmux.isOwn($0) ? $0 : nil }
        guard observed != nil || pane != nil || resume != nil else { return nil }

        var script = #"root="${CODEX_HOME:-$HOME/.codex}/sessions""# + "\n"
        let tail = #"tail -c \#(remoteTailBytes) < "$f""# + (then.map { " | " + $0 + "; exit 0" } ?? "; exit")
        let read = #"if [ -f "$f" ] && [ ! -L "$f" ]; then "# + tail + "; fi"
        if let rollout, let hookID, hookID == observed {
            script += #"f="$root/\#(rollout.1)/\#(rollout.2)/\#(rollout.3)/\#(rollout.0)""# + "\n" + read + "\n"
        }
        func byID(_ id: UUID) -> String {
            #"""
            set -- "$root"/*/*/*/rollout-*-\#(id.uuidString.lowercased()).jsonl
            [ "$#" -eq 1 ] || exit 0
            f=$1
            \#(read)

            """#
        }
        if let observed { script += byID(observed) }
        if let pane {
            script += openCodexRollout(pane: pane, thread: observed) + "\n" + read + "\n"
        }
        if observed == nil, let resume { script += byID(resume) }
        return script + "exit 0"
    }

    /// A prompt, an option value or the source of a fork can also be a UUID. Only a resume argument counts.
    private static func resumedThread(_ argv: [String]) -> UUID? {
        var args = argv.dropFirst()
        func positional() -> String? {
            while let arg = args.popFirst() {
                switch arg {
                case "-c", "--config", "-m", "--model", "-C", "--cd", "-p", "--profile": _ = args.popFirst()
                case "--no-daemon", "--all": continue
                default: return arg
                }
            }
            return nil
        }
        guard positional() == "resume", let id = positional() else { return nil }
        return UUID(uuidString: id)
    }

    /// Start at the agent's own PID or its single remote pane. Stop at the agent rather than following tools it runs.
    static func openAgentFile(pid: String, executable: String, filename: String) -> String {
        return #"""
            open_files() {
                pid=\#(pid)
                for depth in 1 2 3 4; do
                    [ "$pid" -gt 0 ] 2>/dev/null || return
                    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
                    if printf '%s\n' "${exe##*/}" | grep -Eq \#(ShellQuote.word(executable)); then
                        if [ -d "/proc/$pid/fd" ]; then
                            readlink /proc/"$pid"/fd/* 2>/dev/null
                        else
                            lsof -nP -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p'
                        fi
                        return
                    fi
                    printf '%s\n' "${exe##*/}" | grep -Eq '^(sh|bash|zsh|fish|dash|env|node)$' || return
                    pid=$(pgrep -P "$pid" 2>/dev/null)
                done
            }
            f=$(open_files | LC_ALL=C grep -E \#(ShellQuote.word(filename)) | sort -u)
            case "$f" in *'
            '*) exit 0
            esac
            """#
    }

    static func panePID(_ pane: String) -> String {
        #"$(tmux list-panes -s -t \#(ShellQuote.word("=" + pane + ":")) -F '#{pane_pid}' 2>/dev/null)"#
    }

    private static func openCodexRollout(pane: String, thread: UUID?) -> String {
        let id = thread?.uuidString.lowercased() ?? "[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}"
        let day = "[0-9]{4}/[0-9]{2}/[0-9]{2}"
        return openAgentFile(
            pid: panePID(pane), executable: "^codex(-.*)?$",
            filename: "^/.*/sessions/\(day)/rollout-[0-9T:-]+-\(id)[.]jsonl$")
    }
}
