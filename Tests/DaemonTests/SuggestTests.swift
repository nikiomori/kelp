import Core
import Foundation
import Testing

@testable import Daemon

/// How a model on this Mac is asked to fill in code (`editor.suggest`): each family's markers, which model is picked,
/// and what the servers' answers come to.
@Suite struct SuggestTests {
    @Test(arguments: [
        ("qwen2.5-coder:1.5b-base", "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>"),
        ("Qwen2.5-Coder-7B-Instruct-GGUF", "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>"),
        ("codegemma:2b-code", "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>"),
        ("codestral:22b", "[SUFFIX]b[PREFIX]a"),
        ("deepseek-coder:1.3b-base", "<｜fim▁begin｜>a<｜fim▁hole｜>b<｜fim▁end｜>"),
        ("starcoder2:3b", "<fim_prefix>a<fim_suffix>b<fim_middle>"),
        ("granite-code:3b", "<fim_prefix>a<fim_suffix>b<fim_middle>"),
        ("hf.co/JetBrains/Mellum-4b-base-gguf", "<filename>src/x.swift\n<fim_suffix>b<fim_prefix>a<fim_middle>")
    ])
    func eachFamilyHasItsOwnMarkers(model: String, text: String) {
        #expect(FillIn.prompt(model: model, prefix: "a", suffix: "b", path: "src/x.swift")?.text == text)
    }

    @Test(arguments: [
        (
            "qwen2.5-coder:1.5b-base",
            "<|file_sep|>Item.swift\nstruct Item {}\n<|file_sep|>src/x.swift\n<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>"
        ),
        (
            "starcoder2:3b",
            "<file_sep>Item.swift\nstruct Item {}<file_sep><fim_prefix>src/x.swift\na<fim_suffix>b<fim_middle>"
        ),
        (
            "mellum-4b-base",
            "<filename>Item.swift\nstruct Item {}\n<filename>src/x.swift\n<fim_suffix>b<fim_prefix>a<fim_middle>"
        ),
        ("codestral:22b", "[SUFFIX]b[PREFIX]a")   // reads one file: the others are left out
    ])
    func otherFilesGoFirstForTheModelsThatReadSeveral(model: String, text: String) {
        let extra = [SuggestChunk(path: "Item.swift", text: "struct Item {}")]
        #expect(FillIn.prompt(model: model, prefix: "a", suffix: "b", path: "src/x.swift", extra: extra)?.text == text)
    }

    @Test func aChatModelOrAnUnknownOneIsntAsked() {
        #expect(FillIn.prompt(model: "qwen3:8b", prefix: "a", suffix: "b", path: "") == nil)
        #expect(FillIn.prompt(model: "llama3.2", prefix: "a", suffix: "b", path: "") == nil)
    }

    @Test func aBaseModelIsPickedBeforeAChatTunedOne() {
        #expect(FillIn.pick(["qwen3:8b", "qwen2.5-coder:7b", "qwen2.5-coder:1.5b-base"]) == "qwen2.5-coder:1.5b-base")
        #expect(FillIn.pick(["qwen3:8b", "qwen2.5-coder:7b"]) == "qwen2.5-coder:7b")
        #expect(FillIn.pick(["qwen3:8b"]) == nil)
    }

    @Test func serversListTheirModelsEachTheirOwnWay() throws {
        let ollama = Data(#"{"models":[{"name":"qwen2.5-coder:1.5b-base","size":1}]}"#.utf8)
        #expect(try LocalModels.modelNames(ollama, ollama: true) == ["qwen2.5-coder:1.5b-base"])
        let openAI = Data(#"{"object":"list","data":[{"id":"qwen2.5-coder-7b"}]}"#.utf8)
        #expect(try LocalModels.modelNames(openAI, ollama: false) == ["qwen2.5-coder-7b"])
        #expect(try LocalModels.modelNames(Data(#"{"status":"ok"}"#.utf8), ollama: false) == nil)   // something else
    }

    @Test func anAnswersTextIsWhereEachServerPutsIt() throws {
        #expect(try LocalModels.answer(Data(#"{"response":"x + 1","done":true}"#.utf8), ollama: true) == "x + 1")
        #expect(try LocalModels.answer(Data(#"{"choices":[{"text":"x + 1"}]}"#.utf8), ollama: false) == "x + 1")
    }

    @Test func ollamaIsAskedRawAndTheOthersWithAtMostFourStops() throws {
        let prompt = try #require(FillIn.prompt(model: "qwen2.5-coder", prefix: "a", suffix: "b", path: ""))
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        func body(_ ollama: Bool) throws -> [String: Any] {
            let server = LocalModels.Server(name: "s", base: base, ollama: ollama, models: [])
            let data = try #require(try LocalModels.request(server, model: "m", prompt: prompt).httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let ollama = try body(true)
        #expect(ollama["raw"] as? Bool == true)
        #expect((ollama["options"] as? [String: Any])?["stop"] as? [String] == prompt.stop)
        let openAI = try body(false)
        #expect((openAI["stop"] as? [String])?.count == 4)
        #expect(openAI["prompt"] as? String == prompt.text)
    }

    @Test func withNoServerListeningThereIsNoModelAndNoAnswer() async throws {
        let models = LocalModels(known: [("Ollama", 9, true), ("LM Studio", 9, false)])   // port 9: nothing listens
        #expect(await models.models() == [])
        #expect(try await models.suggest(prefix: "a", suffix: "", path: "/x.swift", model: nil).problem == .noServer)

    }

    @Test func theDaemonAnswersBothOverTheWire() async throws {
        let (d, c, _) = try daemon()
        defer { d.stop() }
        _ = try await c.call(EditorSuggestModels())   // whatever runs on this Mac: only that it answers
        let answer = try await c.call(
            EditorSuggest(prefix: "a", suffix: "", path: "/x.swift", model: "no-such-model"))
        #expect(answer.text == nil && answer.problem != nil)   // no server, or none with that model
    }

    @Test func aWarmUpAsksForOneTokenAndAMemoryWarningPutsTheModelAway() throws {
        let prompt = try #require(FillIn.prompt(model: "qwen2.5-coder", prefix: "a", suffix: "b", path: ""))
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        let server = LocalModels.Server(name: "Ollama", base: base, ollama: true, models: [])
        let warm = try #require(try LocalModels.request(server, model: "m", prompt: prompt, tokens: 1).httpBody)
        let options = try #require(try JSONSerialization.jsonObject(with: warm) as? [String: Any])["options"]
        #expect((options as? [String: Any])?["num_predict"] as? Int == 1)
        let away = try LocalModels.unloadRequest(server, model: "m")
        #expect(away.url?.path == "/api/generate")
        let data = try #require(away.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["keep_alive"] as? Int == 0 && body["model"] as? String == "m")
    }

    @Test(
        arguments: [
            (SuggestCloud.mercury, nil, "https://api.inceptionlabs.ai/v1/fim/completions", "mercury-edit-2"),
            (.codestral, nil, "https://api.mistral.ai/v1/fim/completions", "codestral-latest"),
            (
                .codestral, "https://codestral.mistral.ai", "https://codestral.mistral.ai/v1/fim/completions",
                "codestral-latest"
            ),
            (.openai, "https://llm.example.com/v1", "https://llm.example.com/v1/completions", "qwen2.5-coder-7b")
        ] as [(SuggestCloud, String?, String, String)])
    func eachCloudIsAskedAtItsOwnAddressWithTheKey(cloud: SuggestCloud, url: String?, endpoint: String, model: String)
        throws
    {
        let ask = EditorSuggest(
            prefix: "a", suffix: "b", path: "x.swift", model: cloud == .openai ? model : nil, cloud: cloud, url: url)
        let request = try #require(try CloudModels.request(ask, cloud: cloud, key: "k"))
        #expect(request.url?.absoluteString == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == model)
        if cloud == .openai {
            #expect(
                body["prompt"] as? String == "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>" && body["suffix"] == nil)
        } else {
            #expect(body["prompt"] as? String == "a" && body["suffix"] as? String == "b")
        }
    }

    @Test func anOpenAIServerNeedsAnAddressAndAModelItKnows() throws {
        func ask(_ url: String?, _ model: String) throws -> URLRequest? {
            try CloudModels.request(
                EditorSuggest(prefix: "", suffix: "", path: "", model: model, cloud: .openai, url: url), cloud: .openai,
                key: "k")
        }
        #expect(try ask(nil, "qwen2.5-coder") == nil)
        #expect(try ask("https://x", "gpt-4o") == nil)   // a chat model: its fill-in markers aren't known
    }

    @Test func aCloudsAnswerIsReadWhereverItPutsIt() throws {
        #expect(try CloudModels.answer(Data(#"{"choices":[{"index":0,"text":"x + 1"}]}"#.utf8)) == "x + 1")
        #expect(try CloudModels.answer(Data(#"{"choices":[{"message":{"content":"x + 1"}}]}"#.utf8)) == "x + 1")
        #expect(try CloudModels.answer(Data(#"{"error":{"message":"bad key"}}"#.utf8)) == nil)
    }

    @Test func aCloudsKeyIsSavedAndRemovedInTheKeychain() async throws {
        let (d, c, _) = try daemon()
        defer { d.stop() }
        _ = try await c.call(EditorSuggestKey(cloud: .codestral, key: ""))
        #expect(try await c.call(EditorSuggestKey(cloud: .codestral)) == false)
        #expect(try await c.call(EditorSuggestKey(cloud: .codestral, key: "k")) == true)
        #expect(try await c.call(EditorSuggestKey(cloud: .mercury)) == false)   // each provider its own
        #expect(try await c.call(EditorSuggestKey(cloud: .codestral, key: "")) == false)
    }

    @Test(arguments: [
        (401, SuggestProblem.keyRejected), (403, .keyRejected), (404, .modelMissing), (504, .notAnswering),
        (500, .failed), (429, .failed)
    ])
    func anErrorAnswerSaysWhatWentWrong(status: Int, problem: SuggestProblem) {
        #expect(LocalModels.problem(status: status) == problem)
    }

    @Test func aDownloadReadsOllamasLinesAndStopsWhenNothingListens() async throws {
        let step = try LocalModels.step(
            Data(#"{"status":"pulling 1a2b","digest":"x","total":1000,"completed":420}"#.utf8))
        #expect(step.completed == 420 && step.total == 1000 && step.error == nil)
        #expect(try LocalModels.step(Data(#"{"error":"pull model manifest: file does not exist"}"#.utf8)).error != nil)
        let models = LocalModels(known: [], ollama: URL(string: "http://127.0.0.1:9"), waits: 1)   // nothing listens
        await #expect(throws: RPCError.self) { try await models.pull(EditorSuggestPull(model: "m").model, conn: 0) }
        let (d, c, _) = try daemon()
        defer { d.stop() }
        _ = try await c.call(EditorSuggestPullCancel())   // none going on: nothing to stop
    }

    @Test(arguments: [
        ("let total = items.", true),   // mid-line: the rest of the line
        ("func f() {\n    let a = 1\n    ", true),   // a new line inside a block: one line
        ("func f() {\n    ", false),   // just opened a block: its body may take several
        ("if ready:\n    ", false),
        ("", true)
    ])
    func anAnswerIsOneLineUnlessABlockWasJustOpened(prefix: String, oneLine: Bool) {
        #expect(FillIn.oneLine(before: prefix) == oneLine)
    }

    @Test func aOneLineAnswerStopsAtTheLinesEnd() throws {
        let prompt = try #require(FillIn.prompt(model: "qwen2.5-coder", prefix: "a", suffix: "b", path: ""))
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        let server = LocalModels.Server(name: "Ollama", base: base, ollama: true, models: [])
        let data = try #require(try LocalModels.request(server, model: "m", prompt: prompt, oneLine: true).httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(((body["options"] as? [String: Any])?["stop"] as? [String])?.last == "\n")
    }

    @Test func anAnswerTheModelWasntSureOfShowsNothing() throws {
        #expect(!FillIn.sure([-0.01, -0.1, -0.2, -3]))   // one token it guessed: hidden
        #expect(FillIn.sure([-0.01, -0.5, -0.7]))
        #expect(FillIn.sure(nil) && FillIn.sure([]))   // a server that doesn't tell: shown
        let ollama = Data(
            #"{"response":"a\nb","logprobs":[{"token":"a","logprob":-0.1},{"token":"\n","logprob":-2},{"token":"b","logprob":-5}]}"#
                .utf8)
        #expect(try LocalModels.logprobs(ollama, ollama: true) == [-0.1])   // the first line's only
        let openAI = Data(#"{"choices":[{"text":"x","logprobs":{"tokens":["x"],"token_logprobs":[-0.3]}}]}"#.utf8)
        #expect(try LocalModels.logprobs(openAI, ollama: false) == [-0.3])
        #expect(try LocalModels.logprobs(Data(#"{"response":"x"}"#.utf8), ollama: true) == nil)
    }
}
