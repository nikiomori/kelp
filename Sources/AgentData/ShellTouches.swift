import Foundation

/// What a shell command touched, read from its text: the files it printed or searched, the files it wrote, and what it
/// reached outside (sites, hosts, package managers). Agents read files with `cat`, `sed -n` and `rg` about as often as
/// with their own Read tool, so a map without these would miss half of what was read. Limit: it reads the command as
/// written. A path built at run time (`$VAR`, a subshell, a loop) isn't seen, and a script the command runs is one
/// opaque step.
public enum ShellTouches {
    public enum Touch: Equatable, Sendable {
        /// A file printed, or a folder or file searched (`search` true).
        case read(String, search: Bool)
        /// A file written, moved to, copied to, deleted.
        case wrote(String)
        /// A site, by host (and port, for a local server), with the verb that reached it ("curl").
        case site(String, verb: String)
        /// A host reached over ssh, scp or rsync.
        case host(String, verb: String)
        /// A package manager that installed or resolved something.
        case packages(String, verb: String)
        /// A command whose place has a fixed name: `gh` (github.com), a git remote.
        case remote(String, verb: String)
    }

    /// Returns what `command` touched. Relative paths are kept relative to the folder each part runs in: the start one,
    /// or the one a `cd` before it moved to, so `cd Sources && cat a.swift` reads `Sources/a.swift`.
    public static func parse(_ command: String) -> [Touch] {
        var out: [Touch] = [], dir = ""
        for part in parts(of: withoutHeredocs(command)) {
            let (words, redirects) = split(part)
            var plain = words[...]
            while let first = plain.first, first.contains("="), first.first?.isLetter == true { plain.removeFirst() }
            for target in redirects { out.append(.wrote(join(dir, target))) }
            guard let verb = plain.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let args = Array(plain.dropFirst())
            if verb == "cd" {
                if let to = args.first { dir = to.hasPrefix("/") || to.hasPrefix("~") ? to : join(dir, to) }
                continue
            }
            out += touches(verb: verb, args: args).map { relative($0, to: dir) }
        }
        var seen: [Touch] = []
        for touch in out where !seen.contains(touch) { seen.append(touch) }
        return seen
    }

    private static func touches(verb: String, args: [String]) -> [Touch] {
        let paths = args.filter { !$0.hasPrefix("-") && looksLikePath($0) }
        switch verb {
        case "cat", "head", "tail", "less", "more", "nl", "wc", "bat", "file", "stat", "strings", "xxd", "jq":
            return paths.map { .read($0, search: false) }
        case "sed":
            // The first word that isn't a flag is the script, unless -e gave it.
            let words = args.filter { !$0.hasPrefix("-") && !$0.isEmpty }
            let files = (args.contains("-e") ? words[...] : words.dropFirst()).filter(looksLikePath)
            if args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") && $0.count <= 3 }) {
                return files.map { .wrote($0) }
            }
            return args.contains("-n") ? files.map { .read($0, search: false) } : []
        case "rg", "grep", "ag", "ack", "fd", "find":
            // The first word that isn't a flag is the pattern (find's is the folder).
            var rest = args.filter { !$0.hasPrefix("-") }
            if verb != "find" && verb != "fd", !args.contains("-e"), !args.contains("-f"), !rest.isEmpty {
                rest.removeFirst()
            }
            let targets = rest.filter { !$0.contains("://") && !$0.hasPrefix("$") && !$0.contains("*") }
            return (targets.isEmpty ? ["."] : targets).map { .read($0, search: !isFile($0)) }
        case "tee": return paths.map { .wrote($0) }
        case "touch", "rm", "truncate": return paths.map { .wrote($0) }
        case "mv", "cp", "ln", "install": return paths.last.map { [.wrote($0)] } ?? []
        case "curl", "wget", "http", "xh":
            return args.compactMap(site).map { .site($0, verb: verb) }
        case "open":
            return args.compactMap(site).map { .site($0, verb: verb) }
        case "ssh", "mosh":
            return args.first { !$0.hasPrefix("-") }.map { [.host(hostPart($0), verb: verb)] } ?? []
        case "scp", "rsync", "sftp":
            return args.compactMap { arg -> Touch? in
                guard !arg.hasPrefix("-"), let colon = arg.firstIndex(of: ":"), !arg.hasPrefix("/") else { return nil }
                return .host(hostPart(String(arg[..<colon])), verb: verb)
            }
        case "gh": return [.remote("github.com", verb: (["gh"] + args.prefix(2)).joined(separator: " "))]
        case "git":
            let sub = args.first { !$0.hasPrefix("-") } ?? ""
            return ["push", "pull", "fetch", "clone", "ls-remote"].contains(sub)
                ? [.remote("git remote", verb: "git " + sub)] : []
        case "brew", "npm", "pnpm", "yarn", "pip", "pip3", "cargo", "gem", "bun", "uv", "swift", "go":
            let sub = args.first { !$0.hasPrefix("-") } ?? ""
            let installs = ["install", "i", "add", "update", "upgrade", "resolve", "get", "sync"]
            if verb == "swift" {
                return args.first == "package" && installs.contains(args.dropFirst().first ?? "")
                    ? [.packages("SwiftPM", verb: "swift package " + (args.dropFirst().first ?? ""))] : []
            }
            return installs.contains(sub) ? [.packages(verb == "brew" ? "Homebrew" : verb, verb: "\(verb) \(sub)")] : []
        default: return []
        }
    }

    /// The command's parts, split at `&&`, `||`, `;`, `|`, `&` and newlines, each as words with quotes taken off. A
    /// redirection is a word of its own (`>`, `>>`, `2>&1`, `<<`).
    static func parts(of command: String) -> [[String]] {
        var parts: [[String]] = [], words: [String] = [], word = "", quote: Character?, any = false
        func endWord() {
            if any { words.append(word) }
            word = ""
            any = false
        }
        func endPart() {
            endWord()
            if !words.isEmpty { parts.append(words) }
            words = []
        }
        var chars = Array(command)[...]
        while let c = chars.popFirst() {
            if let open = quote {
                if c == open {
                    quote = nil
                } else if c == "\\", open == "\"", let next = chars.popFirst() {
                    word.append(next)
                } else {
                    word.append(c)
                }
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                any = true
            case "\\":
                if let next = chars.popFirst(), next != "\n" {
                    word.append(next)
                    any = true
                }
            case " ", "\t": endWord()
            case "\n", ";": endPart()
            case "|":
                if chars.first == "|" { chars.removeFirst() }
                endPart()
            case "&":
                if chars.first == ">" {
                    endWord()
                    chars.removeFirst()
                    words.append(chars.first == ">" ? "&>>" : "&>")
                    if chars.first == ">" { chars.removeFirst() }
                } else {
                    if chars.first == "&" { chars.removeFirst() }
                    endPart()
                }
            case ">", "<":
                // A file descriptor before it (2>) belongs to the operator.
                let fd = any && word.allSatisfy(\.isNumber) ? word : ""
                if fd.isEmpty {
                    endWord()
                } else {
                    word = ""
                    any = false
                }
                var op = fd + String(c)
                while let next = chars.first,
                    next == ">" || next == "<" || next == "&" || op.hasSuffix("&") && next.isNumber
                {
                    op.append(chars.removeFirst())
                }
                words.append(op)
            default:
                word.append(c)
                any = true
            }
        }
        endPart()
        return parts
    }

    /// The command without the bodies of its heredocs (`cat > f <<'EOF'` … `EOF`): their lines are a file's text, not
    /// commands.
    static func withoutHeredocs(_ command: String) -> String {
        var kept: [Substring] = [], until: String?
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = until {
                if line.trimmingCharacters(in: .whitespaces) == end { until = nil }
                continue
            }
            kept.append(line)
            if let match = line.firstMatch(of: /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/) { until = String(match.1) }
        }
        return kept.joined(separator: "\n")
    }

    /// Takes redirections out of a part's words, and returns what `>`, `>>` and `&>` write to (not `/dev/null`).
    private static func split(_ words: [String]) -> (plain: [String], writes: [String]) {
        var plain: [String] = [], writes: [String] = [], index = 0
        while index < words.count {
            let word = words[index]
            guard let op = word.drop(while: \.isNumber).first, op == ">" || op == "<" || word.hasPrefix("&>") else {
                plain.append(word)
                index += 1
                continue
            }
            let bare = word.drop(while: \.isNumber)
            if bare.hasSuffix("&") || bare.last?.isNumber == true {
                index += bare.last?.isNumber == true ? 1 : 2   // 2>&1, >&2
                continue
            }
            let target = index + 1 < words.count ? words[index + 1] : ""
            if bare.hasPrefix(">") || bare.hasPrefix("&>"), looksLikePath(target), !target.hasPrefix("/dev/") {
                writes.append(target)
            }
            index += 2
        }
        return (plain, writes)
    }

    private static func looksLikePath(_ word: String) -> Bool {
        guard !word.isEmpty, !word.contains("://"), !word.hasPrefix("$"), !word.contains("*"), !word.contains("{"),
            word != "-"
        else { return false }
        return word.contains("/") || word.contains(".") || word == "."
    }

    private static func isFile(_ word: String) -> Bool {
        let last = (word as NSString).lastPathComponent
        return last.contains(".") && !last.hasPrefix(".") && !word.hasSuffix("/") && last != "." && last != ".."
    }

    private static func site(_ word: String) -> String? {
        guard let url = URL(string: word), let scheme = url.scheme, ["http", "https"].contains(scheme),
            let host = url.host
        else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private static func hostPart(_ word: String) -> String {
        String(word.split(separator: "@").last ?? Substring(word))
    }

    private static func join(_ dir: String, _ path: String) -> String {
        if dir.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") { return path }
        return (dir as NSString).appendingPathComponent(path)
    }

    private static func relative(_ touch: Touch, to dir: String) -> Touch {
        switch touch {
        case .read(let path, let search): .read(join(dir, path), search: search)
        case .wrote(let path): .wrote(join(dir, path))
        default: touch
        }
    }
}
