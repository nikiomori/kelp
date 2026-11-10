import Foundation

/// What a command is called where a tab or a row has room for a few words: "swift build" for
/// `cd /x && swift build --product kelp > log 2>&1`, the file's name for a script.
enum CommandName {
    /// Steps that only prepare what comes after them.
    private static let setup: Set<String> = [
        "cd", "pushd", "export", "unset", "set", "source", ".", "for", "while", "if"
    ]
    /// Words in front of the program.
    private static let lead: Set<String> = ["do", "then", "exec", "time", "env", "sudo", "nohup", "command"]

    static func of(_ command: String) -> String {
        let steps = command.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";")
            .split { $0 == ";" || $0 == "\n" }
        return steps.lazy.compactMap(name).first
            ?? String(command.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    }

    /// The program and up to two plain words after it ("npm run dev"); nil for a step that runs nothing to speak of.
    private static func name(_ step: Substring) -> String? {
        let words = (step.split(separator: "|").first ?? "").split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"()")) }
            .drop { lead.contains($0) || isAssignment($0) }
        guard let program = words.first, !program.isEmpty, !setup.contains(program) else { return nil }
        return ([(program as NSString).lastPathComponent] + words.dropFirst().prefix(while: isPlain).prefix(2)).joined(
            separator: " ")
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "=") else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A subcommand's word, not a flag, a path, a number or a redirection.
    private static func isPlain(_ word: String) -> Bool {
        word.first?.isLetter == true
            && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
    }
}
