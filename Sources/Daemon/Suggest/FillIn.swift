import Foundation

/// How each family of code models is asked to fill in the middle: its own markers around the code before and after the
/// cursor, and the tokens that end its answer.
enum FillIn {
    struct Prompt: Equatable {
        let text: String
        let stop: [String]
    }

    /// The prompt for `model`, or nil when its family isn't one Kelp knows how to ask.
    static func prompt(model: String, prefix: String, suffix: String, path: String) -> Prompt? {
        let name = model.lowercased()
        if name.contains("qwen") && name.contains("coder") || name.contains("codegemma") {
            return Prompt(
                text: "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>",
                stop: ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|file_separator|>"])
        }
        if name.contains("codestral") {
            return Prompt(text: "[SUFFIX]\(suffix)[PREFIX]\(prefix)", stop: ["</s>"])
        }
        if name.contains("deepseek-coder") {
            return Prompt(
                text: "<｜fim▁begin｜>\(prefix)<｜fim▁hole｜>\(suffix)<｜fim▁end｜>", stop: ["<｜end▁of▁sentence｜>"])
        }
        if name.contains("mellum") {
            let file = (path as NSString).lastPathComponent
            return Prompt(
                text: "<filename>\(file)\n<fim_suffix>\(suffix)<fim_prefix>\(prefix)<fim_middle>",
                stop: ["<|endoftext|>", "<filename>"])
        }
        if name.contains("starcoder") || name.contains("granite") && name.contains("code") {
            return Prompt(
                text: "<fim_prefix>\(prefix)<fim_suffix>\(suffix)<fim_middle>", stop: ["<|endoftext|>", "<file_sep>"])
        }
        return nil
    }

    /// The model to ask when none is named: one Kelp can ask, a base model before a chat-tuned one, as those fill in
    /// code better.
    static func pick(_ models: [String]) -> String? {
        let able = models.filter { prompt(model: $0, prefix: "", suffix: "", path: "") != nil }
        return able.first { $0.lowercased().contains("base") } ?? able.first
    }
}
