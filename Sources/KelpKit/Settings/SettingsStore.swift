import Core
import Foundation
import Observation

/// ~/.kelp/settings.json, owned by the daemon so the CLI and agents can change it too.
/// Reads are synchronous from the last copy; writes go through the daemon and come back as `event.settings`.
@MainActor
@Observable
package final class SettingsStore {
    let app: AppModel
    init(app: AppModel) { self.app = app }
    private(set) var values: [String: JSONValue] = [:]
    /// Keys with a set still on its way: the daemon's answer to an older one (a colour dragged, a stepper held) mustn't
    /// put back a value the user already moved past.
    private var inFlight: [String: Int] = [:]
    /// The last set on its way: each waits for the one before, as calls leave on threads of their own and could pass it.
    private var lastSet: Task<Void, Never>?

    func load() async {
        // else a banner: what's shown may not be settings.json
        if let fetched = await app.call(SettingsGet()) { received(fetched) }
    }

    /// The daemon's settings (its event, or a load): a key still being set here keeps the value set here.
    func received(_ incoming: [String: JSONValue]) {
        var incoming = incoming
        for key in inFlight.keys { incoming[key] = values[key] }
        apply(incoming)
    }

    func apply(_ incoming: [String: JSONValue]) {
        guard incoming != values else { return }
        // The skills only depend on their switches: don't rewrite their files (on main) for every other setting.
        let skills = { (entries: [String: JSONValue]) in entries.filter { $0.key.hasPrefix("agents.skills.") } }
        let skillsChanged = values.isEmpty || skills(incoming) != skills(values)
        values = incoming
        app.themes.apply()
        if skillsChanged { AgentSkills.write(app) }
        if !app.extensions.extensions.isEmpty,
            app.extensions.disabled(incoming["extensions.disabled"]) != app.extensions.disabledLoaded
        {
            app.extensions.reload()
        }
    }

    /// What Kelp itself sets per language: prose reads best wrapped.
    private static let languageDefaults: [String: [String: JSONValue]] = [
        "markdown": ["editor.wordWrap": .bool(true)], "plaintext": ["editor.wordWrap": .bool(true)]
    ]

    /// `language`'s own value for `key`: settings.json's `"[markdown]": { … }` block, as in VS Code, then Kelp's default for it.
    private func own(_ key: String, _ language: String) -> JSONValue? {
        if case .object(let block)? = values["[\(language)]"], let found = block[key] { return found }
        return Self.languageDefaults[language]?[key]
    }

    /// A setting's value (`language`: for that language's files), or the default its spec declares.
    func value(_ key: String, language: String? = nil) -> JSONValue? {
        if let language, let found = own(key, language) { return found }
        if let found = values[key] { return found }
        for section in app.extensions.all.settings {
            if let spec = section.specs.first(where: { $0.key == key }) { return spec.default }
        }
        return nil
    }
    package func string(_ key: String, language: String? = nil) -> String? { value(key, language: language)?.string }
    /// The share of a plan limit that alerts (`usage.alertAt`, "80"); nil: never ("off"). One place for its default.
    package var usageAlertAt: Int? { Int(string("usage.alertAt") ?? "80") }
    package func bool(_ key: String, language: String? = nil) -> Bool? { value(key, language: language)?.bool }
    package func number(_ key: String, language: String? = nil) -> Double? {
        guard let raw = value(key, language: language)?.number else { return nil }
        return app.extensions.all.settings.lazy.flatMap(\.specs).first { $0.key == key }?.clamped(raw) ?? raw
    }

    /// A row's `requires`: "key" is on (true, or a value that isn't empty, off, never or 0), "key=value", "key!=value".
    func meets(_ rule: String?) -> Bool {
        guard let rule else { return true }
        func text(_ key: String) -> String {
            switch value(key) {
            case .bool(let bool)?: return bool ? "true" : "false"
            case .int(let int)?: return String(int)
            case .double(let double)?: return String(double)
            case .string(let string)?: return string
            default: return ""
            }
        }
        if let range = rule.range(of: "!=") {
            return text(String(rule[..<range.lowerBound])) != rule[range.upperBound...]
        }
        if let range = rule.range(of: "=") {
            return text(String(rule[..<range.lowerBound])) == rule[range.upperBound...]
        }
        return !["", "false", "off", "never", "0"].contains(text(rule))
    }

    /// `language`'s own block, whether it had the key or not (Settings' language picker); nil `value` takes it out.
    func setOwn(_ key: String, _ value: JSONValue?, language: String) {
        var block: [String: JSONValue] = [:]
        if case .object(let existing)? = values["[\(language)]"] { block = existing }
        block[key] = value
        set("[\(language)]", block.isEmpty ? nil : .object(block))
    }

    /// The languages settings.json has a block for.
    var languagesSet: [String] {
        values.keys.filter { $0.hasPrefix("[") && $0.hasSuffix("]") }.map { String($0.dropFirst().dropLast()) }.sorted()
    }

    /// Shows a value without saving it (the palette trying themes on); `set` keeps one, `preview(key, saved)` goes back.
    func preview(_ key: String, _ value: JSONValue?) {
        var next = values
        next[key] = value
        apply(next)
    }

    /// `language`: a value that language has of its own changes there, where it's read; any other changes for all files.
    package func set(_ key: String, _ value: JSONValue?, language: String? = nil) {
        if let language, own(key, language) != nil {
            var block: [String: JSONValue] = [:]
            if case .object(let existing)? = values["[\(language)]"] { block = existing }
            block[key] = value
            return set("[\(language)]", .object(block))
        }
        var next = values
        next[key] = value
        apply(next)   // optimistic; the daemon's echo confirms
        inFlight[key, default: 0] += 1
        lastSet = Task { [lastSet] in
            await lastSet?.value
            let error = await app.tryCall(SettingsSet(key: key, value: value)).error
            inFlight[key] = inFlight[key].flatMap { $0 > 1 ? $0 - 1 : nil }
            // Not saved: say so and show what settings.json really holds again, instead of a value that reverts later.
            if let error {
                Banner.show(String(localized: "Couldn't change “\(key)”: \(error)"), style: .error)
                await load()
            }
        }
    }
}
