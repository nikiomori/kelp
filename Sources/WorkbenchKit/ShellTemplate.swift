import Core
import Foundation

/// `${name}` placeholders in a shell command. `fill` never puts a value into the command's text: each one is assigned
/// to a shell variable first (as one single-quoted word, at the top level where that is always right) and the
/// placeholder becomes a reference to it, so a value with $(…), quotes or a newline stays data whatever surrounds it.
/// The variables are exported too, so a command that hands text to another shell can pass `"$KELP_V1"` along as data.
/// In a single-quoted string another shell runs as code (`sh -c '…'`, `bash -c`, `eval '…'`), a placeholder is left
/// as `"${KELP_Vn}"` for that shell to expand from the environment, as data. On an ssh line (quoted or bare), the value
/// goes in as its text, quoted for the host's shell, because this shell's variables don't reach the host.
public enum ShellTemplate {
    /// Fills the placeholders in `template`. When `value(name)` is nil, the placeholder stays as written (the shell's
    /// own `${HOME}`). `named` holds values that are also exported as `KELP_<name>` (`workspace.path` as
    /// `KELP_workspace_path`), for a command that reads `"$KELP_title"` itself. That is the plainest way to keep a
    /// value as data, whatever shell or program gets it.
    public static func fill(_ template: String, named: [String: String] = [:], _ value: (String) -> String?) -> String {
        var assign: [String] = [], out = "", rest = Substring(template), quotes = ShellQuotes()
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound]
            quotes.read(rest[..<open.lowerBound])
            if let filled = value(String(rest[open.upperBound..<close])),
                let remote = quotes.remoteLiteral(filled) ?? quotes.bareRemoteLiteral(filled)
            {
                out += remote
                quotes.inserted()   // for a shell on another machine, the value goes in quoted for that shell
            } else if let filled = value(String(rest[open.upperBound..<close])) {
                let name = "KELP_V\(assign.count + 1)"
                assign.append("\(name)=\(ShellQuote.word(filled))")
                out += quotes.reference(name)
                quotes.inserted()
            } else {
                out += rest[open.lowerBound...close]
                quotes.read(rest[open.lowerBound...close])
            }
            rest = rest[rest.index(after: close)...]
        }
        assign += named.sorted { $0.key < $1.key }.compactMap { k, v in envName(k).map { "\($0)=\(ShellQuote.word(v))" }
        }
        return assign.isEmpty ? out + rest : "export " + assign.joined(separator: " ") + "; " + out + rest
    }

    /// Returns `KELP_` plus the name, with anything but letters, digits and _ written as _. Returns nil for an empty
    /// name.
    public static func envName(_ name: String) -> String? {
        let safe = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return safe.isEmpty ? nil : "KELP_" + safe
    }

    /// Fills placeholders in plain text (a title, a prompt), putting values in as they are.
    public static func substitute(_ template: String, _ value: (String) -> String) -> String {
        var out = "", rest = Substring(template)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound] + value(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// Tracks where a shell would be at this point of a template (inside quotes, a comment, a here-document), and whether
/// that string is code another program runs (`sh -c '…'`, `/bin/bash -c "…"`, `eval`, a here-document fed to `sh`,
/// `python -c`…). This decides how a variable reference is written. In code, it is written as the variable's name for
/// that program to read. A shell expands it as data, and an interpreter that doesn't is handed the name, not the value.
struct ShellQuotes {
    var inSingle = false, inDouble = false, inComment = false
    /// `codeQuote` says the quoted string open now is code for another program. `remoteQuote` says it is for a shell on
    /// another machine (`ssh host "…"`), which this shell's variables don't reach.
    var codeQuote = false, remoteQuote = false
    /// A here-document's end word, once `<<WORD` was read. `expands` means WORD was unquoted, so $(…) inside the
    /// document runs. `code` means the document is fed to a shell, which runs its text.
    var pendingDoc: (word: String, expands: Bool, code: Bool)?, inDoc: (word: String, expands: Bool, code: Bool)?
    private var line = "", last: Character = "\n", outer: [(Bool, Bool)] = []

    mutating func read(_ text: Substring) {
        var escaped = false, i = text.startIndex
        while i < text.endIndex {
            let character = text[i]
            defer {
                last = character
                i = text.index(after: i)
            }
            if character == "\n" {
                if let doc = inDoc, line.trimmingCharacters(in: .whitespaces) == doc.word {
                    inDoc = nil
                } else if inDoc == nil, let pending = pendingDoc {
                    inDoc = pending
                    pendingDoc = nil
                }
                inComment = false
                line = ""
                escaped = false
                continue
            }
            line.append(character)
            if inDoc != nil || inComment { continue }
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", !inSingle {
                escaped = true
                continue
            }
            if character == "#", !inSingle, !inDouble, last == " " || last == "\t" || last == "\n" || last == ";" {
                inComment = true
                continue
            }
            // $(…) starts unquoted, whatever is around it
            if character == "$", !inSingle, text[i...].dropFirst().first == "(" {
                outer.append((inSingle, inDouble))
                inDouble = false
                i = text.index(after: i)
                continue
            }
            if character == ")", !inSingle, !inDouble, let saved = outer.popLast() {
                (inSingle, inDouble) = saved
                continue
            }
            if character == "'", !inDouble {
                inSingle.toggle()
                if inSingle {
                    codeQuote = Self.runsCode(line.dropLast())
                    remoteQuote = Self.runsRemotely(line.dropLast())
                }
            } else if character == "\"", !inSingle {
                inDouble.toggle()
                if inDouble {
                    codeQuote = Self.runsCode(line.dropLast())
                    remoteQuote = Self.runsRemotely(line.dropLast())
                }
            }
            if character == "<", !inSingle, !inDouble, text[i...].hasPrefix("<<"), !text[i...].hasPrefix("<<<") {
                var rest = text[text.index(i, offsetBy: 2)...].drop { $0 == "-" || $0 == " " }
                let quoted = rest.first == "'" || rest.first == "\""
                if quoted { rest = rest.dropFirst() }
                let word = String(rest.prefix { !" \t\n'\";<>|&".contains($0) })
                if !word.isEmpty {
                    pendingDoc = (
                        word, !quoted, Self.feedsShell(line + text[text.index(after: i)...].prefix { $0 != "\n" })
                    )
                }
                i = text.index(after: i)   // skips the second <
            }
        }
    }

    /// Returns a reference to `name`'s value, as this spot needs it. Bare, it gets quotes. In '…', the quotes close
    /// around it. In "…" or a here-document, it goes in as it is.
    func reference(_ name: String) -> String {
        // the shell that the document is fed to expands it, as data
        if let doc = inDoc, doc.code, doc.expands { return "\"\\${\(name)}\"" }
        if inDoc != nil || inComment { return "${\(name)}" }
        if inDouble && codeQuote { return "\\\"\\${\(name)}\\\"" }   // \"\${KELP_V1}\": left for the inner shell, quoted
        if inDouble { return "${\(name)}" }
        if inSingle && codeQuote { return "\"${\(name)}\"" }   // the inner shell expands it, quoted, as data
        if inSingle { return "'\"${\(name)}\"'" }
        // Bare after `sh -c` or `eval`, the word is the script. There it reads "${KELP_V1}", one word expanded as data.
        return Self.runsCode(Substring(line)) ? "'\"${\(name)}\"'" : "\"${\(name)}\""
    }

    /// Whether what comes before a quote hands it to a program as code: `sh -c`, `/bin/bash -lc`, `env zsh -c`, `eval`,
    /// `python3 -c`, `perl -e`, `ruby -e`, `node -e`, `osascript -e`.
    static func runsCode(_ before: Substring) -> Bool {
        let shell = #"(eval|(ba|z|da|k)?sh(\s+-[A-Za-z]+)*\s+-[A-Za-z]*c[A-Za-z]*)"#
        let other = #"((python3?|perl|ruby|node|osascript)(\s+-[A-Za-z]+)*\s+-[A-Za-z]*[ce][A-Za-z]*)"#
        return before.range(of: #"(^|[\s;|&(/])("# + shell + "|" + other + #")\s*$"#, options: .regularExpression)
            != nil
    }

    /// Whether what comes before a quote hands it to ssh as a command for the host.
    static func runsRemotely(_ before: Substring) -> Bool {
        before.range(of: #"(^|[\s;|&(/])ssh\b[^'"]*$"#, options: .regularExpression) != nil
    }

    /// In a string that ssh runs on a host, returns `value` quoted for the host's shell, then quoted again for the
    /// quotes it sits in here, so this shell hands the quoted word on unchanged. Returns nil anywhere else.
    func remoteLiteral(_ value: String) -> String? {
        guard remoteQuote, inDoc == nil, !inComment else { return nil }
        let word = ShellQuote.word(value)
        if inSingle { return "'" + ShellQuote.word(word) + "'" }
        if inDouble {
            return word.reduce(into: "") { out, ch in
                if "\\\"$`".contains(ch) { out.append("\\") }
                out.append(ch)
            }
        }
        return nil
    }

    /// For a bare placeholder on an ssh line (`ssh host git log ${branch}`), returns the value as a word quoted for the
    /// host's shell, then quoted again for this one, because ssh joins its words into one command line for the host's
    /// shell.
    func bareRemoteLiteral(_ value: String) -> String? {
        guard !inSingle, !inDouble, inDoc == nil, !inComment,
            line.range(of: #"(^|[\s;|&(/])ssh\s(\\[;|&]|[^;|&])*$"#, options: .regularExpression) != nil
        else { return nil }
        return ShellQuote.word(ShellQuote.word(value))
    }

    /// Whether a shell runs the line's here-document: `sh <<EOF`, `bash -s <<EOF`, `cat <<EOF | sh`.
    static func feedsShell(_ line: Substring) -> Bool {
        line.range(of: #"(^|[\s;|&(/])(ba|z|da|k)?sh\b"#, options: .regularExpression) != nil
    }

    mutating func inserted() { last = "x" }   // a value just went in, so a # right after it doesn't start a comment
}
