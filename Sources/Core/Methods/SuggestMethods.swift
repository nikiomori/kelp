import Foundation

/// Gray text for the editor: what a model on this Mac (Ollama, LM Studio, llama-server) writes between the code before
/// and after the cursor. Nil when no model answers. Kelp runs no model of its own.
public struct EditorSuggest: InternalMethod {
    public static let name = "editor.suggest"
    public typealias Result = String?
    /// A slow answer is no use: the person typed on long before it.
    public static var timeout: TimeInterval? { 10 }
    public var prefix: String, suffix: String, path: String
    /// The model to ask, as its server names it; nil or empty picks one that fills in code.
    public var model: String?
    /// True to have the model read the code and write nothing: a file just opened, so the first suggestion doesn't
    /// wait for the model to load. Answers nil.
    public var warm: Bool?
    public init(prefix: String, suffix: String, path: String, model: String? = nil, warm: Bool? = nil) {
        self.prefix = prefix
        self.suffix = suffix
        self.path = path
        self.model = model
        self.warm = warm
    }
}

/// The models the servers running on this Mac offer, in the order a model is picked when none is named: those that fill
/// in code first, a base one before a chat-tuned one.
public struct EditorSuggestModels: InternalMethod {
    public static let name = "editor.suggestModels"
    public typealias Result = [SuggestModel]
    public init() {}
}

public struct SuggestModel: Codable, Sendable, Equatable {
    /// The model's name on its server ("qwen2.5-coder:1.5b-base"), and the server ("Ollama").
    public var id: String, server: String
    /// Whether Kelp knows how to ask this model to fill in code.
    public var fillsIn: Bool
    public init(id: String, server: String, fillsIn: Bool) {
        self.id = id
        self.server = server
        self.fillsIn = fillsIn
    }
}
