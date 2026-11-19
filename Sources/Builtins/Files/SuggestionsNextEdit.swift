import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// The next edit (Settings › Editor › Predict the next edit): Sweep Next-Edit in a llama-server that kelpd starts,
/// with llama.cpp installed by Homebrew in a terminal tab when it isn't there.
extension Suggestions {
    /// Whether the next edit is wanted: its setting, while suggestions are on somewhere. `followNextEdit` starts and
    /// stops its model as this changes, whoever changed the setting (the card, Settings, `kelp settings`, settings.json).
    var nextEditWanted: Bool { app.settings[SettingKeys.nextEdit] && app.settings[SettingKeys.suggestions] != .off }

    /// On: starts the model now, so the first edit doesn't wait for its download. Off: stops it, giving its memory back.
    /// Only on a change: a next edit already on when Kelp opens starts with the first edit that asks for it.
    func followNextEdit() {
        track(owner: self, now: false) { [weak self] in
            self?.nextEditWanted ?? false
        } changed: { [weak self] on in
            Task { [weak self] in
                if on { await self?.startNextEdit() } else { await self?.stopNextEdit() }
            }
        }
    }

    func stopNextEdit() async {
        nextEditSetup = nil
        await app.quiet(EditorNextEditStop())
    }

    func startNextEdit() async {
        nextEditSetup = .starting
        // Its own deadline, none: the first start downloads 1.5 GB. A failure has its own row, so no banner.
        let answer = await app.tryCall(EditorNextEditStart()).value
        guard nextEditWanted else { return }   // switched off while it started
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
