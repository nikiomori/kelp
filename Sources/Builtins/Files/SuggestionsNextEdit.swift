import AppKit
import Core
import EditorKit
import KelpKit

/// The next edit (Settings › Editor › Predict the next edit): Sweep Next-Edit in a llama-server that kelpd starts,
/// with llama.cpp installed by Homebrew in a terminal tab when it isn't there.
extension Suggestions {
    /// On: starts the model now, so the first edit doesn't wait for its download. Off: stops it, giving its memory back.
    func setNextEdit(_ on: Bool) async {
        app.settings.set(SettingKeys.nextEdit, on)
        guard on else {
            nextEditSetup = nil
            await app.quiet(EditorNextEditStop())
            return
        }
        await startNextEdit()
    }

    func startNextEdit() async {
        nextEditSetup = .starting
        let answer = await app.quiet(EditorNextEditStart())
        switch answer?.problem {
        case .noServer:
            let found = await app.quiet(ProcessWhich(commands: ["brew"])) ?? [:]
            nextEditSetup = .needs(found["brew"] == nil ? .download : .homebrew)
        case nil where answer != nil: nextEditSetup = nil
        default: nextEditSetup = .failed
        }
    }

    /// Installs llama.cpp with Homebrew in a terminal tab, then starts the model; without Homebrew, opens its page.
    func installLlama() {
        guard nextEditSetup == .needs(.homebrew) else {
            if let page = URL(string: "https://github.com/ggml-org/llama.cpp#quick-start") {
                PreviewLinks.openOutside(page)
            }
            return
        }
        runInTerminal("brew install llama.cpp", title: String(localized: "Install llama.cpp")) { [weak self] in
            await self?.startNextEdit()
        }
    }

    /// Asks the daemon for the cursor's lines as the model would write them next, while Kelp is in front.
    func nextEditProvider(name: String) -> (NextEdit.Ask) async -> String? {
        let app = app
        return { ask in
            guard NSApp.isActive else { return nil }
            return await app.quiet(Self.request(ask, path: name))?.text
        }
    }

    nonisolated static func request(_ ask: NextEdit.Ask, path: String) -> EditorNextEdit {
        EditorNextEdit(
            path: path, changes: (ask.earlier + [ask.latest]).map { NextEditChange(old: $0.old, new: $0.new) },
            original: ask.original, current: ask.current)
    }
}
