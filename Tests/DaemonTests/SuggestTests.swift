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
        ("hf.co/JetBrains/Mellum-4b-base-gguf", "<filename>x.swift\n<fim_suffix>b<fim_prefix>a<fim_middle>")
    ])
    func eachFamilyHasItsOwnMarkers(model: String, text: String) {
        #expect(FillIn.prompt(model: model, prefix: "a", suffix: "b", path: "/p/x.swift")?.text == text)
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
        #expect(try await models.suggest(prefix: "a", suffix: "", path: "/x.swift", model: nil) == nil)

    }

    @Test func theDaemonAnswersBothOverTheWire() async throws {
        let (d, c, _) = try daemon()
        defer { d.stop() }
        _ = try await c.call(EditorSuggestModels())   // whatever runs on this Mac: only that it answers
        #expect(
            try await c.call(EditorSuggest(prefix: "a", suffix: "", path: "/x.swift", model: "no-such-model")) == nil)
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
}
