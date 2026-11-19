import Core
import Foundation

/// What the editor's status bar says about suggestions: the model while all is well, and otherwise why no gray text
/// comes, in the warning colour when it takes the person to fix it (as Restricted beside it does).
struct SuggestionStatus: Equatable {
    let text: String
    var needsYou = false

    /// Everything the status depends on. `mode` is the file's language's setting, `everywhere` the setting for all.
    struct Inputs {
        var mode: SuggestMode, everywhere: SuggestMode
        var secret = false
        var model: SuggestModel?
        /// Whether the servers on this Mac were asked yet.
        var known = true
        var pause: SuggestionPause?
        var cloud: (name: String, hasKey: Bool?)?
        var problem: SuggestProblem?
        var loading = false
        /// Whether an edit is offered in the file now.
        var editOffered = false
    }

    /// Nil to say nothing: suggestions are off and there's no model to turn on.
    static func of(_ s: Inputs) -> SuggestionStatus? {
        guard let status = plain(s), s.editOffered, !status.needsYou else { return plain(s) }
        return SuggestionStatus(text: String(localized: "\(status.text) · Edit Below"))
    }

    private static func plain(_ s: Inputs) -> SuggestionStatus? {
        if s.mode == .off {
            if s.everywhere != .off { return SuggestionStatus(text: String(localized: "Off in This File")) }
            return s.model == nil ? nil : SuggestionStatus(text: String(localized: "Suggestions Off"))
        }
        if s.secret { return SuggestionStatus(text: String(localized: "Off in This File")) }
        if s.mode == .cloud, let cloud = s.cloud { return cloudStatus(cloud.name, hasKey: cloud.hasKey, s) }
        if let pause = s.pause { return SuggestionStatus(text: pause.title) }
        let server = s.model?.server ?? "Ollama"
        switch s.problem {
        case .noServer: return warning(String(localized: "\(server) Isn't Running"))
        case .noModel: return warning(String(localized: "No Code Model"))
        case .modelMissing: return warning(String(localized: "Model Not Found"))
        case .notAnswering: return warning(String(localized: "\(server) Isn't Answering"))
        case .failed, .keyMissing, .keyRejected: return warning(String(localized: "\(server) Failed"))
        case nil: break
        }
        guard let model = s.model else { return s.known ? warning(String(localized: "No Code Model")) : nil }
        return named(Suggestions.shortName(model.id), loading: s.loading)
    }

    private static func cloudStatus(_ name: String, hasKey: Bool?, _ s: Inputs) -> SuggestionStatus {
        if hasKey == false || s.problem == .keyMissing { return warning(String(localized: "Cloud: No Key")) }
        switch s.problem {
        case .keyRejected: return warning(String(localized: "\(name): Key Rejected"))
        case .notAnswering, .noServer: return warning(String(localized: "\(name) Isn't Answering"))
        case .failed, .noModel, .modelMissing: return warning(String(localized: "\(name) Failed"))
        case .keyMissing, nil: return named(String(localized: "Cloud · \(name)"), loading: s.loading)
        }
    }

    private static func named(_ name: String, loading: Bool) -> SuggestionStatus {
        SuggestionStatus(text: loading ? String(localized: "\(name) · Loading…") : name)
    }

    private static func warning(_ text: String) -> SuggestionStatus { SuggestionStatus(text: text, needsYou: true) }
}
