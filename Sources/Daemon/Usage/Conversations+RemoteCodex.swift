import Agents
import Core
import Foundation

extension Conversations {
    /// Older session records have no thread ID. Recover the last main hook if it's still in their terminal log.
    func lastCodexReport(of session: Session) -> UUID? {
        guard UUID(uuidString: session.id) != nil,
            let tail = Data(tail: LiveSession.logLimit, of: history.appendingPathComponent(session.id + ".log")),
            tail.range(of: Data("conv=".utf8)) != nil
        else { return nil }
        var carry = ""
        for message in ProgramStatus.scan(String(decoding: tail, as: UTF8.self), carry: &carry).reversed() {
            if case .report(let report) = message, report.id == nil, let conv = report.conv {
                return UUID(uuidString: conv)
            }
        }
        return nil
    }

    /// A hook's rollout names the thread currently open, even after an in-session resume. Use its basename under
    /// Codex's sessions folder, so a hook cannot redirect the read to an arbitrary file on the host.
    static func codexTailScript(_ session: Session, thread: UUID?, transcript: String?) -> String? {
        let name = transcript.map { ($0 as NSString).lastPathComponent }
        let filename = /rollout-([0-9]{4})-([0-9]{2})-([0-9]{2})T[0-9]{2}-[0-9]{2}-[0-9]{2}-([a-fA-F0-9-]{36})\.jsonl/
        let rollout = name?.wholeMatch(of: filename)
        let hookID = rollout.flatMap { UUID(uuidString: String($0.4)) }
        let resume = resumedThread(session.argv)
        let observed = thread ?? hookID
        let pane = session.tmux.flatMap { Tmux.isOwn($0) ? $0 : nil }
        guard observed != nil || pane != nil || resume != nil else { return nil }

        var script = #"root="${CODEX_HOME:-$HOME/.codex}/sessions""# + "\n"
        let read = #"if [ -f "$f" ] && [ ! -L "$f" ]; then tail -c \#(remoteTailBytes) < "$f"; exit; fi"#
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

    /// The pane runs Codex itself or a shell/node wrapper around it. Stop at the agent: its tools can launch other
    /// chats. Multiple panes, wrapper children or open rollouts leave the identity unresolved.
    private static func openCodexRollout(pane: String, thread: UUID?) -> String {
        let id = thread?.uuidString.lowercased() ?? "[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}"
        return #"""
            open_rollout() {
                pid=$(tmux list-panes -s -t \#(ShellQuote.word("=" + pane + ":")) -F '#{pane_pid}' 2>/dev/null)
                for depth in 1 2 3 4; do
                    [ "$pid" -gt 0 ] 2>/dev/null || return
                    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
                    if printf '%s\n' "${exe##*/}" | grep -Eq '^codex(-.*)?$'; then
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
            day='[0-9]{4}/[0-9]{2}/[0-9]{2}'
            f=$(open_rollout | LC_ALL=C grep -E "^/.*/sessions/$day/rollout-[0-9T:-]+-\#(id)[.]jsonl$" | sort -u)
            case "$f" in *'
            '*) exit 0
            esac
            """#
    }
}
