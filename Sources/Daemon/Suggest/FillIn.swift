import Core
import Foundation

/// How each family of code models is asked to fill in the middle: its own markers around the code before and after the
/// cursor, and the tokens that end its answer.
enum FillIn {
    struct Prompt: Equatable {
        let text: String
        let stop: [String]
    }

    /// The prompt for `model`, or nil when its family isn't one Kelp knows how to ask. Code from other files (`extra`)
    /// goes first, each under its path, for the families trained to read several files (Qwen2.5-Coder, StarCoder2,
    /// Mellum); the others get the file alone.
    static func prompt(model: String, prefix: String, suffix: String, path: String, extra: [SuggestChunk] = [])
        -> Prompt?
    {
        let name = model.lowercased()
        if name.contains("qwen") && name.contains("coder") {
            let files =
                extra.isEmpty
                ? ""
                : extra.map { "<|file_sep|>\($0.path)\n\($0.text)\n" }.joined()
                    + "<|file_sep|>\(path)\n"
            return Prompt(
                text: files + "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>",
                stop: ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|repo_name|>"])
        }
        if name.contains("codegemma") {
            return Prompt(
                text: "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>",
                stop: ["<|file_separator|>", "<|fim_prefix|>", "<eos>"])
        }
        if name.contains("codestral") {
            return Prompt(text: "[SUFFIX]\(suffix)[PREFIX]\(prefix)", stop: ["</s>"])
        }
        if name.contains("deepseek-coder") {
            return Prompt(
                text: "<｜fim▁begin｜>\(prefix)<｜fim▁hole｜>\(suffix)<｜fim▁end｜>", stop: ["<｜end▁of▁sentence｜>"])
        }
        if name.contains("mellum") {
            let files = extra.map { "<filename>\($0.path)\n\($0.text)\n" }.joined()
            return Prompt(
                text: files + "<filename>\(path)\n<fim_suffix>\(suffix)<fim_prefix>\(prefix)<fim_middle>",
                stop: ["<|endoftext|>", "<filename>"])
        }
        if name.contains("starcoder") || name.contains("granite") && name.contains("code") {
            let files = extra.isEmpty ? "" : extra.map { "<file_sep>\($0.path)\n\($0.text)" }.joined() + "<file_sep>"
            return Prompt(
                text: files
                    + "<fim_prefix>\(extra.isEmpty ? "" : path + "\n")\(prefix)<fim_suffix>\(suffix)<fim_middle>",
                stop: ["<|endoftext|>", "<file_sep>"])
        }
        return nil
    }

    /// Whether the answer is one line: mid-line it's the rest of the line, and on an empty line it's that line, unless
    /// the line above opens a block (`{`, `:`), whose body may take several. Measured on Kelp's code, a new line is
    /// guessed right far less often than the rest of one (16 % against 42 %), so a long guess there mostly misleads.
    static func oneLine(before prefix: String) -> Bool {
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        guard let current = lines.last, current.allSatisfy(\.isWhitespace) else { return true }
        let above = lines.dropLast().last { !$0.allSatisfy(\.isWhitespace) }?.trimmingCharacters(in: .whitespaces)
        return !(above?.hasSuffix("{") == true || above?.hasSuffix(":") == true)
    }

    /// The model to ask when none is named: one Kelp can ask, a base model before a chat-tuned one, as those fill in
    /// code better.
    static func pick(_ models: [String]) -> String? {
        let able = models.filter { prompt(model: $0, prefix: "", suffix: "", path: "") != nil }
        return able.first { $0.lowercased().contains("base") } ?? able.first
    }
}
