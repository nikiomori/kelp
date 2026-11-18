import Foundation

/// Gray text for the editor: what a model writes between the code before and after the cursor. Nil when no model
/// answers. The model is one on this Mac (Ollama, LM Studio, llama-server), or a cloud one (`cloud`) with the key saved
/// for it in the login keychain. Kelp runs no model of its own.
public struct EditorSuggest: InternalMethod {
    public static let name = "editor.suggest"
    public typealias Result = SuggestAnswer
    /// A slow answer is no use: the person typed on long before it.
    public static var timeout: TimeInterval? { 10 }
    public var prefix: String, suffix: String, path: String
    /// The model to ask, as its server names it; nil or empty picks one that fills in code.
    public var model: String?
    /// True to have the model read the code and write nothing: a file just opened, so the first suggestion doesn't
    /// wait for the model to load. Answers nil.
    public var warm: Bool?
    /// Code from other files lately open or edited, oldest first, for a model that reads more than one file.
    public var extra: [SuggestChunk]?
    /// The cloud provider to ask instead of this Mac, and its server when not the provider's own.
    public var cloud: SuggestCloud?
    public var url: String?
    public init(
        prefix: String, suffix: String, path: String, model: String? = nil, warm: Bool? = nil,
        extra: [SuggestChunk]? = nil, cloud: SuggestCloud? = nil, url: String? = nil
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.path = path
        self.model = model
        self.warm = warm
        self.extra = extra
        self.cloud = cloud
        self.url = url
    }
}

/// What a model wrote, or why nothing came: the status bar names the problem and its card offers the fix.
public struct SuggestAnswer: Codable, Sendable, Equatable {
    public var text: String?
    public var problem: SuggestProblem?
    public init(text: String? = nil, problem: SuggestProblem? = nil) {
        self.text = text
        self.problem = problem
    }
}

/// Why no suggestion came.
public enum SuggestProblem: String, Codable, Sendable, CaseIterable {
    /// Nothing listens where Ollama, LM Studio or llama-server would.
    case noServer
    /// A server runs, but none of its models fills in code.
    case noModel
    /// The model named in Settings isn't on any server.
    case modelMissing
    /// The cloud provider has no key saved, or turned the key down.
    case keyMissing, keyRejected
    /// No answer in time, or no connection.
    case notAnswering
    /// The server answered with an error.
    case failed
}

/// A cloud service that fills in code: Inception's Mercury Edit 2, Mistral's Codestral, or any server with OpenAI's
/// completions API.
public enum SuggestCloud: String, Codable, Sendable, CaseIterable {
    case mercury, codestral, openai
}

/// Whether a key is saved for `cloud`, after saving `key` when one is given (an empty one removes it). Keys live in the
/// login keychain, never in settings.json.
public struct EditorSuggestKey: InternalMethod {
    public static let name = "editor.suggestKey"
    public typealias Result = Bool
    public var cloud: SuggestCloud, key: String?
    public init(cloud: SuggestCloud, key: String? = nil) {
        self.cloud = cloud
        self.key = key
    }
}

/// A piece of another file: lines around where it was edited, or its start (imports and types).
public struct SuggestChunk: Codable, Sendable, Equatable {
    /// The file's path in its project.
    public var path: String, text: String
    public init(path: String, text: String) {
        self.path = path
        self.text = text
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
