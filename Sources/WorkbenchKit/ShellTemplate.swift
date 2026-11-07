import Core
import Foundation

/// `${name}` placeholders in a shell command. `fill` never puts a value into the command's text: each one is assigned
/// to a shell variable first (as one single-quoted word, at the top level where that is always right) and the
/// placeholder becomes a reference to it, so a value with $(…), quotes or a newline stays data whatever surrounds it.
/// The variables are exported too, so a command that hands text to another shell can pass `"$KELP_V1"` along as data.
/// In a single-quoted string another shell runs as code (`sh -c '…'`, `bash -c`, `eval '…'`), a placeholder is left
/// as `"${KELP_Vn}"` for that shell to expand from the environment, as data. On an ssh line (quoted or bare) the value
/// goes in as its text, quoted for the host's shell, which this one's variables don't reach.
public enum ShellTemplate {
    /// `value(name)` nil: the placeholder stays as written (the shell's own `${HOME}`). `named`: values exported as
    /// `KELP_<name>` too (`workspace.path` as `KELP_workspace_path`), for a command that reads `"$KELP_title"` itself:
    /// the plainest way to keep a value data, whatever shell or program gets it.
    public static func fill(_ template: String, named: [String: String] = [:], _ value: (String) -> String?) -> String {
        var assign: [String] = [], out = "", rest = Substring(template), quotes = ShellQuotes()
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound]
            quotes.read(rest[..<open.lowerBound])
            if let v = value(String(rest[open.upperBound..<close])),
                let remote = quotes.remoteLiteral(v) ?? quotes.bareRemoteLiteral(v)
            {
                out += remote
                quotes.inserted()   // for a shell on another machine: the value, quoted for that shell
            } else if let v = value(String(rest[open.upperBound..<close])) {
                let name = "KELP_V\(assign.count + 1)"
                assign.append("\(name)=\(IDE.shellWord(v))")
                out += quotes.reference(name)
                quotes.inserted()
            } else {
                out += rest[open.lowerBound...close]
                quotes.read(rest[open.lowerBound...close])
            }
            rest = rest[rest.index(after: close)...]
        }
        assign += named.sorted { $0.key < $1.key }.compactMap { k, v in envName(k).map { "\($0)=\(IDE.shellWord(v))" } }
        return assign.isEmpty ? out + rest : "export " + assign.joined(separator: " ") + "; " + out + rest
    }

    /// `KELP_` and the name with anything but letters, digits and _ as _; nil for one that's empty.
    public static func envName(_ name: String) -> String? {
        let safe = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return safe.isEmpty ? nil : "KELP_" + safe
    }

    /// Plain text (a title, a prompt): values put in as they are.
    public static func substitute(_ template: String, _ value: (String) -> String) -> String {
        var out = "", rest = Substring(template)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound] + value(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// Where a shell would be at this point of a template (inside quotes, a comment, a here-document), and whether that
/// string is code another program runs (`sh -c '…'`, `/bin/bash -c "…"`, `eval`, a here-document fed to `sh`, `python
/// -c`…). Decides how a variable reference is written: in code, as the variable's name for that program to read (a
/// shell expands it as data; an interpreter that doesn't is handed the name, not the value).
struct ShellQuotes {
    var inSingle = false, inDouble = false, inComment = false
    /// The quoted string open now is code for another program; `remoteQuote`: for a shell on another machine (`ssh host
    /// "…"`), which this one's variables don't reach.
    var codeQuote = false, remoteQuote = false
    /// A here-document's end word once `<<WORD` was read; `expands`: unquoted WORD, so $(…) inside it runs; `code`: fed
    /// to a shell, which runs its text.
    var pendingDoc: (word: String, expands: Bool, code: Bool)?, inDoc: (word: String, expands: Bool, code: Bool)?
    private var line = "", last: Character = "\n", outer: [(Bool, Bool)] = []

    mutating func read(_ s: Substring) {
        var escaped = false, i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            defer {
                last = c
                i = s.index(after: i)
            }
            if c == "\n" {
                if let d = inDoc, line.trimmingCharacters(in: .whitespaces) == d.word {
                    inDoc = nil
                } else if inDoc == nil, let p = pendingDoc {
                    inDoc = p
                    pendingDoc = nil
                }
                inComment = false
                line = ""
                escaped = false
                continue
            }
            line.append(c)
            if inDoc != nil || inComment { continue }
            if escaped {
                escaped = false
                continue
            }
            if c == "\\", !inSingle {
                escaped = true
                continue
            }
            if c == "#", !inSingle, !inDouble, last == " " || last == "\t" || last == "\n" || last == ";" {
                inComment = true
                continue
            }
            if c == "$", !inSingle, s[i...].dropFirst().first == "(" {   // $(…) starts unquoted, whatever is around it
                outer.append((inSingle, inDouble))
                inDouble = false
                i = s.index(after: i)
                continue
            }
            if c == ")", !inSingle, !inDouble, let o = outer.popLast() {
                (inSingle, inDouble) = o
                continue
            }
            if c == "'", !inDouble {
                inSingle.toggle()
                if inSingle {
                    codeQuote = Self.runsCode(line.dropLast())
                    remoteQuote = Self.runsRemotely(line.dropLast())
                }
            } else if c == "\"", !inSingle {
                inDouble.toggle()
                if inDouble {
                    codeQuote = Self.runsCode(line.dropLast())
                    remoteQuote = Self.runsRemotely(line.dropLast())
                }
            }
            if c == "<", !inSingle, !inDouble, s[i...].hasPrefix("<<"), !s[i...].hasPrefix("<<<") {
                var rest = s[s.index(i, offsetBy: 2)...].drop { $0 == "-" || $0 == " " }
                let quoted = rest.first == "'" || rest.first == "\""
                if quoted { rest = rest.dropFirst() }
                let word = String(rest.prefix { !" \t\n'\";<>|&".contains($0) })
                if !word.isEmpty {
                    pendingDoc = (word, !quoted, Self.feedsShell(line + s[s.index(after: i)...].prefix { $0 != "\n" }))
                }
                i = s.index(after: i)   // the second <
            }
        }
    }

    /// `name`'s value as this spot needs it: bare it gets quotes, in '…' they close around it, in "…" or a here-document
    /// it goes in as is.
    func reference(_ name: String) -> String {
        if let d = inDoc, d.code, d.expands { return "\"\\${\(name)}\"" }   // the shell it's fed to expands it, as data
        if inDoc != nil || inComment { return "${\(name)}" }
        if inDouble && codeQuote { return "\\\"\\${\(name)}\\\"" }   // \"\${KELP_V1}\": left for the inner shell, quoted
        if inDouble { return "${\(name)}" }
        if inSingle && codeQuote { return "\"${\(name)}\"" }   // the inner shell expands it, quoted: data there too
        if inSingle { return "'\"${\(name)}\"'" }
        // Bare after `sh -c` or `eval`: the word is the script. It reads "${KELP_V1}" there, one word expanded as data.
        return Self.runsCode(Substring(line)) ? "'\"${\(name)}\"'" : "\"${\(name)}\""
    }

    /// What comes before a quote hands it to a program as code: `sh -c`, `/bin/bash -lc`, `env zsh -c`, `eval`,
    /// `python3 -c`, `perl -e`, `ruby -e`, `node -e`, `osascript -e`.
    static func runsCode(_ before: Substring) -> Bool {
        let shell = #"(eval|(ba|z|da|k)?sh(\s+-[A-Za-z]+)*\s+-[A-Za-z]*c[A-Za-z]*)"#
        let other = #"((python3?|perl|ruby|node|osascript)(\s+-[A-Za-z]+)*\s+-[A-Za-z]*[ce][A-Za-z]*)"#
        return before.range(of: #"(^|[\s;|&(/])("# + shell + "|" + other + #")\s*$"#, options: .regularExpression)
            != nil
    }

    /// What comes before a quote hands it to ssh as a command for the host.
    static func runsRemotely(_ before: Substring) -> Bool {
        before.range(of: #"(^|[\s;|&(/])ssh\b[^'"]*$"#, options: .regularExpression) != nil
    }

    /// In a string ssh runs on a host: `v` quoted for the host's shell, then for the quotes it sits in here, so this
    /// shell hands that quoted word on unchanged. nil anywhere else.
    func remoteLiteral(_ v: String) -> String? {
        guard remoteQuote, inDoc == nil, !inComment else { return nil }
        let word = IDE.shellWord(v)
        if inSingle { return "'" + IDE.shellWord(word) + "'" }
        if inDouble {
            return word.reduce(into: "") { out, ch in
                if "\\\"$`".contains(ch) { out.append("\\") }
                out.append(ch)
            }
        }
        return nil
    }

    /// Bare on an ssh line (`ssh host git log ${branch}`): ssh joins its words into one command line for the host's shell,
    /// so the value goes as a word quoted for that shell, quoted again for this one.
    func bareRemoteLiteral(_ v: String) -> String? {
        guard !inSingle, !inDouble, inDoc == nil, !inComment,
            line.range(of: #"(^|[\s;|&(/])ssh\s(\\[;|&]|[^;|&])*$"#, options: .regularExpression) != nil
        else { return nil }
        return IDE.shellWord(IDE.shellWord(v))
    }

    /// A line whose here-document a shell runs: `sh <<EOF`, `bash -s <<EOF`, `cat <<EOF | sh`.
    static func feedsShell(_ line: Substring) -> Bool {
        line.range(of: #"(^|[\s;|&(/])(ba|z|da|k)?sh\b"#, options: .regularExpression) != nil
    }

    mutating func inserted() { last = "x" }   // a value just went in: a # right after it doesn't start a comment
}
