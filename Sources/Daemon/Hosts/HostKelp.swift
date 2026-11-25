import Core
import Foundation

/// What Kelp puts on a host for an agent that drives a page from there: `kelp` (a sh script that knows only
/// `kelp browser`), the browser skill told where it runs, and the socket ssh brings back to kelpd (`HostBrowser`). It
/// all goes in `/tmp/kelp-<uid>`, which only the user can open, and nothing goes in the home folder. Not in
/// `/run/user/<uid>`, which systemd removes when the last login ends while the agent in tmux lives on.
enum HostKelp {
    /// The sh that makes the folder and its files on the host, removes the socket an earlier connection left (a new
    /// forwarding can't bind over it), and prints the folder, then a line that says whether the project looks like a
    /// web app there (`webApp`). The folder must be the user's own: on a shared host another user could make it first.
    static func setup(session: String, project: String, skill: String) -> String {
        """
        umask 077
        d="/tmp/kelp-$(id -u)"
        mkdir -p "$d" 2>/dev/null
        if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]
        then
          echo "$d isn't this user's own folder" >&2
          exit 1
        fi
        chmod 700 "$d" && mkdir -p "$d/bin" "$d/shots" "$d/downloads" "$d/plugin/.claude-plugin" \
          "$d/plugin/skills/kelp-browser" || exit 1
        cat > "$d/bin/kelp" <<'KELP_FILE_END'
        \(shim)KELP_FILE_END
        chmod 700 "$d/bin/kelp"
        cat > "$d/plugin/.claude-plugin/plugin.json" <<'KELP_FILE_END'
        {"name": "kelp-browser", "description": "Kelp's browser, from this host"}
        KELP_FILE_END
        cat > "$d/plugin/skills/kelp-browser/SKILL.md" <<'KELP_FILE_END'
        \(skill)
        KELP_FILE_END
        rm -f "$d/\(socketName(session))"
        printf '%s\\n' "$d"
        cd \(RemoteHost.cdArg(project)) 2>/dev/null || exit 0
        for f in \(webFiles.joined(separator: " "))
        do
          if [ -f "$f" ]
          then
            echo "$f"
            break
          fi
        done
        exit 0
        """
    }

    /// Files that say a project is a web app, at the top of the project or one folder in. On a host only their names
    /// are read, not what they hold (`WebApp.found` reads that on this Mac).
    static let webFiles = [
        "package.json", "manage.py", "index.html", "compose.yaml", "compose.yml", "docker-compose.yml",
        "docker-compose.yaml", "*/package.json", "*/manage.py", "*/index.html"
    ]

    /// Reads what `setup` printed: the folder, and the web app's file when there is one.
    static func parse(_ out: String) -> (dir: String, webApp: String?)? {
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        guard let at = lines.firstIndex(where: { $0.hasPrefix("/tmp/kelp-") }) else { return nil }
        return (lines[at], lines.dropFirst(at + 1).first)
    }

    /// The socket's name in the folder: one for each session, so kelpd knows whose page a call is for.
    static func socketName(_ session: String) -> String { "\(session.lowercased()).sock" }

    /// `kelp` on the host (Resources/kelp-on-host.sh). It sends its socket (which says where Kelp's folder is there),
    /// the folder it runs in, the words, and stdin when they need it (`eval -`, or a list of steps with no words), NUL
    /// after each word, to kelpd over the socket. kelpd answers line by line: `o` to stdout, `e` to stderr, and `x`
    /// with the exit code last. With no answer at all, Kelp isn't connected.
    /// It needs curl or python3 to reach the socket, and one of them is on nearly every host.
    static var shim: String { Paths.resource("kelp-on-host", "sh") ?? "" }

    /// The browser skill as an agent on `host` reads it: the same text, with what is different there first.
    static func skill(_ text: String, host: String) -> String {
        let note = """

            ## On \(host)

            You run on \(host), over ssh from the user's Mac. The page draws in Kelp's window on the
            Mac, and `kelp` here (on PATH, else `/tmp/kelp-$(id -u)/bin/kelp`) knows only `kelp browser`.
            `localhost:3000` means this host: Kelp brings the port to the Mac, perhaps under another number,
            which the answer says. Other addresses load through this host, so names only it knows work.
            `--shared` and `preview:` aren't there from a host (serve a folder over http and open its
            localhost address instead). Screenshots, recordings and downloads land on this host, at the path
            the answer prints.

            """
        // After the title, before the rest.
        guard let title = text.range(of: "# Using a web page in Kelp\n") else { return text + note }
        return text.replacingCharacters(in: title, with: text[title] + note)
    }
}
