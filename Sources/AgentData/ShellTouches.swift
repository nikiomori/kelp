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
        var out: [Touch] = [], dir = "", lost = false, outer: (dir: String, lost: Bool)?
        for whole in parts(of: withoutHeredocs(command)) {
            let piped = whole.first == Self.piped, part = piped ? Array(whole.dropFirst()) : whole
            // A subshell's `cd` ends with it: `(cd Vendor && make) && cat README.md` reads ./README.md.
            if part.first?.hasPrefix("(") == true, outer == nil { outer = (dir, lost) }
            defer {
                if part.last?.hasSuffix(")") == true, let back = outer {
                    (dir, lost) = back
                    outer = nil
                }
            }
            // A subshell's parentheses aren't part of its words: `(cd Vendor && ls)`.
            let (words, redirects) = split(
                part.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }.filter { !$0.isEmpty })
            var plain = words[...]
            while let first = plain.first, first.contains("="), first.first?.isLetter == true { plain.removeFirst() }
            for target in redirects where !lost || target.hasPrefix("/") || target.hasPrefix("~") {
                out.append(.wrote(join(dir, target)))
            }
            guard let verb = plain.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let args = Array(plain.dropFirst())
            if verb == "cd" {
                // A folder named at run time (`cd $W`) leaves where the rest runs unknown: its relative paths are left
                // out rather than put under a folder called "$W".
                guard let to = args.first, isPlainPath(to) else {
                    lost = true
                    continue
                }
                dir = to.hasPrefix("/") || to.hasPrefix("~") ? to : join(dir, to)
                if to.hasPrefix("/") || to.hasPrefix("~") { lost = false }
                continue
            }
            out += touches(verb: verb, args: args, piped: piped).filter { !lost || Self.isAbsolute($0) }.map {
                relative($0, to: dir)
            }
        }
        var seen: [Touch] = []
        for touch in out where !seen.contains(touch) { seen.append(touch) }
        return seen
    }

    private static func touches(verb: String, args: [String], piped: Bool = false) -> [Touch] {
        let paths = args.filter { !$0.hasPrefix("-") && looksLikePath($0) && isPlainPath($0) }
        switch verb {
        case "jq":
            // The first word that isn't a flag is the filter (`.version`); the files follow it.
            return args.filter { !$0.hasPrefix("-") }.dropFirst().filter { looksLikePath($0) && isPlainPath($0) }.map {
                .read($0, search: false)
            }
        case "cat", "head", "tail", "less", "more", "nl", "wc", "bat", "file", "stat", "strings", "xxd":
            // What these name is a file, with or without a dot in its name (`cat Makefile`).
            return args.filter { !$0.hasPrefix("-") && isPlainPath($0) }.map { .read($0, search: false) } + globs(args)
        case "ls":
            // A folder listed was looked through, not read as a file.
            return paths.map { .read($0, search: !isFile($0)) } + globs(args)
        case "sed":
            // The first word that isn't a flag is the script, unless -e (or -f) gave it: then the word after each is.
            var words: [String] = [], skip = false
            for arg in args where !arg.isEmpty {
                if skip {
                    skip = false
                } else if arg.hasPrefix("-") {
                    skip = arg == "-e" || arg == "-f"
                } else {
                    words.append(arg)
                }
            }
            let given = args.contains("-e") || args.contains("-f")
            let files = (given ? words[...] : words.dropFirst()).filter {
                looksLikePath($0) && isPlainPath($0)
            }
            if args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") && $0.count <= 3 }) {
                return files.map { .wrote($0) }
            }
            return args.contains("-n") ? files.map { .read($0, search: false) } : []
        case "find":
            // Its folders come first; everything from the first expression on (-name, -exec sed …, \() is no path.
            let folders = args.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" }.filter(isPlainPath)
            return (folders.isEmpty ? ["."] : folders).map { .read($0, search: true) }
        case "rg", "grep", "ag", "ack", "fd":
            // The first word that isn't a flag is the pattern (fd's too); the rest are where it looked.
            // A flag's value isn't a target: `grep -A 3 pat`, `rg -t swift`, `rg -g '*.md'`; `-e`'s is the pattern.
            let valued: Set = [
                "-A", "-B", "-C", "-m", "-e", "-f", "-g", "-t", "-T", "--type", "--glob", "--max-count", "-E"
            ]
            var rest: [String] = [], skip = false
            for arg in args {
                if skip {
                    skip = false
                } else if arg.hasPrefix("-") {
                    skip = valued.contains(arg) && !(verb == "grep" && arg == "-E")
                } else {
                    rest.append(arg)
                }
            }
            if !args.contains("-e"), !args.contains("-f"), !rest.isEmpty { rest.removeFirst() }
            let targets = rest.filter(isPlainPath), globbed = globs(rest)
            if targets.isEmpty && !globbed.isEmpty { return globbed }
            // With no target it searches what a pipe gives it (`ps aux | grep kelp`); grep without -r reads its
            // input; else the folder it runs in.
            let recursive =
                verb != "grep"
                || args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R")) }
                || args.contains("--recursive")
            if targets.isEmpty && (piped || !recursive) { return globbed }
            return (targets.isEmpty ? ["."] : targets).map { .read($0, search: !isFile($0)) } + globbed
        case "tee": return paths.map { .wrote($0) }
        case "touch", "rm", "truncate": return paths.map { .wrote($0) }
        case "mv", "cp", "ln", "install": return paths.last.map { [.wrote($0)] } ?? []
        case "curl", "wget", "http", "xh":
            return args.compactMap(site).map { .site($0, verb: verb) }
        case "open":
            return args.compactMap(site).map { .site($0, verb: verb) }
        case "ssh", "mosh":
            // A flag's value isn't the host: `ssh -i ~/.ssh/key box`, `ssh -p 2222 box`.
            let valued: Set = [
                "-i", "-p", "-l", "-o", "-F", "-J", "-b", "-c", "-D", "-E", "-L", "-R", "-S", "-W", "-w", "-m"
            ]
            var skip = false
            for arg in args {
                if skip {
                    skip = false
                } else if arg.hasPrefix("-") {
                    skip = valued.contains(arg)
                } else {
                    return [.host(hostPart(arg), verb: verb)]
                }
            }
            return []
        case "scp", "rsync", "sftp":
            return args.compactMap { arg -> Touch? in
                guard !arg.hasPrefix("-"), let colon = arg.firstIndex(of: ":"), !arg.hasPrefix("/") else { return nil }
                return .host(hostPart(String(arg[..<colon])), verb: verb)
            }
        case "kelp":
            // Kelp's own commands that leave the project: a page in its browser, a command in one of its machines.
            let sub = Array(args.prefix { $0 != "--" })
            if sub.first == "browser" { return sub.compactMap(site).map { .site($0, verb: "kelp browser") } }
            if sub.first == "vm", sub.count > 2, sub[1] != "list" { return [.host(sub[2], verb: "kelp vm " + sub[1])] }
            return []
        case "gh": return [.remote("github.com", verb: (["gh"] + args.prefix(2)).joined(separator: " "))]
        case "git":
            let sub = args.first { !$0.hasPrefix("-") } ?? ""
            return ["push", "pull", "fetch", "clone", "ls-remote"].contains(sub)
                ? [.remote("", verb: "git " + sub)] : []
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
    /// The first word of a part that reads what a pipe gives it.
    static let piped = "\u{1}|"

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
                let or = chars.first == "|"
                if or { chars.removeFirst() }
                endPart()
                if !or { words = [Self.piped] }   // what follows reads the output before it
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
            // A here-string (`<<< word`) is no heredoc: nothing after it is its body.
            let heads = line.replacing("<<<", with: " ")
            if let match = heads.firstMatch(of: /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/) { until = String(match.1) }
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
            if bare.hasPrefix(">") || bare.hasPrefix("&>"), looksLikePath(target) || isPlainPath(target),
                !target.hasPrefix("/dev/")
            {
                writes.append(target)
            }
            index += 2
        }
        return (plain, writes)
    }

    /// The folders a glob looked through (`Sources/X/*.swift` → `Sources/X`), as searches.
    private static func globs(_ args: [String]) -> [Touch] {
        args.filter { !$0.hasPrefix("-") && $0.contains("*") }.compactMap { word in
            let folder = word.split(separator: "/", omittingEmptySubsequences: false).prefix { !$0.contains("*") }
                .joined(separator: "/")
            if folder.isEmpty { return word.hasPrefix("/") ? nil : .read(".", search: true) }
            return isPlainPath(folder) ? .read(folder, search: true) : nil
        }
    }

    private static func looksLikePath(_ word: String) -> Bool {
        guard !word.isEmpty, !word.contains("://"), !word.hasPrefix("$"), !word.contains("*"), !word.contains("{"),
            word != "-"
        else { return false }
        return word.contains("/") || word.contains(".") || word == "."
    }

    /// A word that can only be a path as written: letters, digits, `. _ - / ~ @ +` (a file name like `a+b.swift`),
    /// not a number, a variable, a glob or a script (`s|a|b|`, `{}`, `$W`).
    private static func isPlainPath(_ word: String) -> Bool {
        guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "._-/~@+".contains($0) }),
            !word.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "." && word.count > 2 })
        else { return false }
        return word.contains("/") || word.contains(".") || word.first?.isLetter == true
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

    private static func isAbsolute(_ touch: Touch) -> Bool {
        switch touch {
        case .read(let path, _), .wrote(let path): path.hasPrefix("/") || path.hasPrefix("~")
        default: true
        }
    }

    private static func relative(_ touch: Touch, to dir: String) -> Touch {
        switch touch {
        case .read(let path, let search): .read(join(dir, path), search: search)
        case .wrote(let path): .wrote(join(dir, path))
        default: touch
        }
    }
}
