import Core
import Foundation

/// The model servers running on this Mac, found where each listens by default, and the one call that asks a model to
/// fill in code. Kelp starts and downloads nothing: what the person runs is what there is.
actor LocalModels {

    struct Server: Equatable {
        let name: String
        let base: URL
        /// Ollama has its own API; the others speak OpenAI's.
        let ollama: Bool
        let models: [String]
    }

    typealias Place = (name: String, port: Int, ollama: Bool)
    /// Where each server listens unless told otherwise.
    static let defaults: [Place] = [("Ollama", 11434, true), ("LM Studio", 1234, false), ("llama-server", 8080, false)]
    private let known: [Place]
    init(known: [Place] = defaults) { self.known = known }
    /// How long what was found is trusted: a server started meanwhile is seen this much later.
    private static let fresh: TimeInterval = 30
    private var found: (servers: [Server], at: Date)?
    private let http = URLSession(configuration: .ephemeral)
    /// Kept for the cloud's answers, so its connection stays open and each keystroke's ask skips a new TLS handshake.
    let cloudHTTP = URLSession(configuration: .ephemeral)
    /// The Ollama model last asked, which a memory warning has Ollama put away at once (it would keep it 5 minutes).
    private var loaded: (server: Server, model: String)?
    private var pressure: DispatchSourceMemoryPressure?

    func servers() async -> [Server] {
        if let found, Date().timeIntervalSince(found.at) < Self.fresh { return found.servers }
        var servers: [Server] = []
        await withTaskGroup(of: (Int, Server?).self) { group in
            for (index, server) in known.enumerated() {
                group.addTask { (index, await self.probe(server.name, port: server.port, ollama: server.ollama)) }
            }
            var byIndex: [Int: Server] = [:]
            for await (index, server) in group { byIndex[index] = server }
            servers = known.indices.compactMap { byIndex[$0] }
        }
        found = servers.isEmpty ? nil : (servers, Date())   // none: look again at once, a server may just be starting
        return servers
    }

    func models() async -> [SuggestModel] {
        let all = await servers().flatMap { server in
            server.models.map {
                SuggestModel(
                    id: $0, server: server.name,
                    fillsIn: FillIn.prompt(model: $0, prefix: "", suffix: "", path: "") != nil)
            }
        }
        let able = all.filter(\.fillsIn), base = { (m: SuggestModel) in m.id.lowercased().contains("base") }
        return able.filter(base) + able.filter { !base($0) } + all.filter { !$0.fillsIn }   // the order `pick` takes
    }

    /// What `model` (else the first that fills in code) writes between `prefix` and `suffix`.
    func suggest(
        prefix: String, suffix: String, path: String, model: String?, warm: Bool = false, extra: [SuggestChunk] = []
    ) async throws -> SuggestAnswer {
        let servers = await servers()
        guard !servers.isEmpty else { return SuggestAnswer(problem: .noServer) }
        let wanted = model.flatMap { $0.isEmpty ? nil : $0 }
        let server =
            wanted.map { name in servers.first { $0.models.contains(name) } }
            ?? servers.first { FillIn.pick($0.models) != nil }
        guard let server, let name = wanted ?? FillIn.pick(server.models),
            let prompt = FillIn.prompt(model: name, prefix: prefix, suffix: suffix, path: path, extra: extra)
        else { return SuggestAnswer(problem: wanted == nil ? .noModel : .modelMissing) }
        do {
            let request = try Self.request(server, model: name, prompt: prompt, tokens: warm ? 1 : 128)
            let (data, response) = try await http.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return SuggestAnswer(problem: Self.problem(status: status)) }
            if server.ollama { remember(server, name) }
            return SuggestAnswer(text: warm ? nil : try Self.answer(data, ollama: server.ollama))
        } catch let error as URLError {
            if error.code == .cannotConnectToHost { found = nil }   // it went away: look again next time
            return SuggestAnswer(problem: error.code == .cannotConnectToHost ? .noServer : .notAnswering)
        }
    }

    /// What an answer's HTTP status says went wrong.
    static func problem(status: Int) -> SuggestProblem {
        switch status {
        case 401, 403: .keyRejected
        case 404: .modelMissing
        case 408, 504: .notAnswering
        default: .failed
        }
    }

    /// Keeps which Ollama model is in memory, and starts listening for the system's memory warnings once.
    private func remember(_ server: Server, _ model: String) {
        loaded = (server, model)
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in Task { await self?.unload() } }
        source.resume()
        pressure = source
    }

    /// Has Ollama put the last model away now: the Mac is short of memory, and agents and builds need it more.
    private func unload() async {
        guard let loaded else { return }
        self.loaded = nil
        do {
            _ = try await http.data(for: try Self.unloadRequest(loaded.server, model: loaded.model))
        } catch {
            Log.rpc.debug("Ollama didn't put \(loaded.model, privacy: .public) away: \(error.localizedDescription)")
        }
    }

    static func unloadRequest(_ server: Server, model: String) throws -> URLRequest {
        var request = URLRequest(url: server.base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        return request
    }

    private func probe(_ name: String, port: Int, ollama: Bool) async -> Server? {
        guard let base = URL(string: "http://127.0.0.1:\(port)") else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(ollama ? "api/tags" : "v1/models"))
        request.timeoutInterval = 0.5
        do {
            let (data, response) = try await http.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let models = try Self.modelNames(data, ollama: ollama)
            else { return nil }
            return Server(name: name, base: base, ollama: ollama, models: models)
        } catch {
            Log.rpc.debug("no model server at \(port, privacy: .public): \(error.localizedDescription)")
            return nil   // nothing listens there, or something else does
        }
    }

    /// The models a server lists: Ollama's `models[].name`, OpenAI's `data[].id`. Nil for another kind of answer.
    static func modelNames(_ data: Data, ollama: Bool) throws -> [String]? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json[ollama ? "models" : "data"] as? [[String: Any]]
        else { return nil }
        return list.compactMap { $0[ollama ? "name" : "id"] as? String }
    }

    /// A short answer, the same each time: a suggestion is a line or a few, and guessing would make it flicker.
    static func request(_ server: Server, model: String, prompt: FillIn.Prompt, tokens: Int = 128) throws -> URLRequest
    {
        var body: [String: Any] = ["model": model, "prompt": prompt.text, "stream": false]
        if server.ollama {
            body["raw"] = true
            body["options"] = ["num_predict": tokens, "temperature": 0, "stop": prompt.stop]
        } else {
            body["max_tokens"] = tokens
            body["temperature"] = 0
            body["stop"] = Array(prompt.stop.prefix(4))   // OpenAI's API takes at most four
            body["cache_prompt"] = true   // llama-server keeps the code it read for the next keystroke
        }
        var request = URLRequest(
            url: server.base.appendingPathComponent(server.ollama ? "api/generate" : "v1/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The text of an answer: Ollama's `response`, OpenAI's `choices[0].text`.
    static func answer(_ data: Data, ollama: Bool) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if ollama { return json["response"] as? String }
        return ((json["choices"] as? [[String: Any]])?.first?["text"]) as? String
    }
}

extension EditorSuggest: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> SuggestAnswer {
        guard let cloud else {
            return try await lsp.models.suggest(
                prefix: prefix, suffix: suffix, path: path, model: model, warm: warm == true, extra: extra ?? [])
        }
        guard warm != true else { return SuggestAnswer() }   // a warm-up would be paid for: the cloud's are loaded
        let key = try await lsp.offloads.run { try Keychain.find(CloudModels.account(cloud)) }
        return try await lsp.models.suggest(self, cloud: cloud, key: key)
    }
}

extension EditorSuggestModels: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [SuggestModel] { await lsp.models.models() }
}

extension Methods {
    static let suggestMethods: [any Answered.Type] = [
        EditorSuggest.self, EditorSuggestModels.self, EditorSuggestKey.self
    ]
}
