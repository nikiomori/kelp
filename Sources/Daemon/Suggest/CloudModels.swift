import Core
import Foundation

/// The cloud services that fill in code, asked with the key the person saved in the login keychain. Each has its own
/// fill-in-the-middle API; a server with OpenAI's completions API gets the model's own markers, as on this Mac.
enum CloudModels {
    static func account(_ cloud: SuggestCloud) -> String { "suggest.\(cloud.rawValue)" }

    /// The request for `cloud`, or nil when it can't be asked: an OpenAI-style server with no address, or a model
    /// whose markers Kelp doesn't know. The key goes only to its provider: Mercury always to Inception, Codestral to
    /// an https address of Mistral's (the free key's codestral.mistral.ai) or else its own; only a server of one's own
    /// is asked wherever the address says.
    static func request(_ ask: EditorSuggest, cloud: SuggestCloud, key: String) throws -> URLRequest? {
        let (prefix, suffix) = (ask.prefix, ask.suffix)
        let named = ask.model.flatMap { $0.isEmpty ? nil : $0 }
        let address = ask.url.flatMap { $0.isEmpty ? nil : $0 }
        let oneLine = FillIn.oneLine(before: prefix)
        var body: [String: Any] = [
            "max_tokens": oneLine ? 48 : 128, "stream": false, "prompt": prefix, "suffix": suffix
        ]
        if oneLine { body["stop"] = ["\n"] }
        let endpoint: String
        switch cloud {
        case .mercury:
            endpoint = "https://api.inceptionlabs.ai/v1/fim/completions"
            body["model"] = named ?? "mercury-edit-2"
        case .codestral:
            endpoint = (address.flatMap(mistral) ?? "https://api.mistral.ai") + "/v1/fim/completions"
            body["model"] = named ?? "codestral-latest"
            body["temperature"] = 0
        case .openai:
            guard let address, let named,
                let prompt = FillIn.prompt(
                    model: named, prefix: prefix, suffix: suffix, path: ask.path)
            else { return nil }
            endpoint = address + "/v1/completions"
            body["model"] = named
            body["prompt"] = prompt.text
            body["suffix"] = nil
            body["temperature"] = 0
            body["stop"] = oneLine ? Array(prompt.stop.prefix(3)) + ["\n"] : Array(prompt.stop.prefix(4))   // at most 4
        }
        guard let target = URL(string: endpoint.replacingOccurrences(of: "/v1/v1/", with: "/v1/")) else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `address` when it's one of Mistral's own over https, else nil.
    static func mistral(_ address: String) -> String? {
        guard let url = URL(string: address), url.scheme == "https", let host = url.host?.lowercased(),
            host == "mistral.ai" || host.hasSuffix(".mistral.ai")
        else { return nil }
        return address
    }

    /// The text of an answer: `choices[0].text` (Inception, OpenAI), or `choices[0].message.content` (Mistral).
    static func answer(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choice = (json["choices"] as? [[String: Any]])?.first
        else { return nil }
        return choice["text"] as? String ?? (choice["message"] as? [String: Any])?["content"] as? String
    }
}

extension LocalModels {
    /// What `ask.cloud` writes for `ask`, with its saved key, or why nothing came.
    func suggest(_ ask: EditorSuggest, cloud: SuggestCloud, key: String?) async throws -> SuggestAnswer {
        guard let key else { return SuggestAnswer(problem: .keyMissing) }
        guard let request = try CloudModels.request(ask, cloud: cloud, key: key) else {
            return SuggestAnswer(problem: .modelMissing)   // a server of one's own with no address or a known model
        }
        do {
            let (data, response) = try await cloudHTTP.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return SuggestAnswer(problem: Self.problem(status: status)) }
            return SuggestAnswer(text: try CloudModels.answer(data))
        } catch is URLError {
            return SuggestAnswer(problem: .notAnswering)
        }
    }
}

extension EditorSuggestKey: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> Bool {
        let account = CloudModels.account(cloud), key = key
        return try await lsp.offloads.run {
            if let key { key.isEmpty ? Keychain.delete(account) : try Keychain.set(key, account: account) }
            return try Keychain.find(account) != nil
        }
    }
}
