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
    /// Keys with a write still on its way. The daemon's answer to an older write (a colour dragged, a stepper held)
    /// mustn't put back a value the user already moved past.
    private var inFlight: [String: Int] = [:]
    /// The last write on its way. Each write waits for the one before, because calls leave on threads of their own and
    /// could overtake it.
    private var lastSet: Task<Void, Never>?

    func load() async {
        // on failure a banner says that what's shown may not be settings.json
        if let fetched = await app.call(SettingsGet()) { received(fetched) }
        if !loaded { loaded = true }
    }
    /// Whether the daemon's settings were asked for once (read, or not readable). The window waits for this to show
    /// its first frame.
    package internal(set) var loaded = false   // set only by `load` (tests aside)

    /// Takes the daemon's settings (from its event, or a load). A key still being set here keeps the value set here.
    func received(_ incoming: [String: JSONValue]) {
        var incoming = incoming
        for key in inFlight.keys { incoming[key] = values[key] }
        apply(incoming)
    }

    /// Applies the settings now in effect. Whatever follows them reads them under observation: the theme
    /// (`ThemeManager.follow`), the extensions switched on and the skills written (`ExtensionRegistry.follow`), and the
    /// views.
    func apply(_ incoming: [String: JSONValue]) {
        if incoming != values { values = incoming }
    }

    /// The defaults Kelp itself sets per language. Prose reads best wrapped.
    private static let languageDefaults: [String: [String: JSONValue]] = [
        "markdown": [SettingKeys.wordWrap.key: .bool(true)], "plaintext": [SettingKeys.wordWrap.key: .bool(true)]
    ]

    /// Returns `language`'s own value for `key`, from settings.json's `"[markdown]": { … }` block (as in VS Code), or
    /// else Kelp's default for that language.
    private func own(_ key: String, _ language: String) -> JSONValue? {
        if case .object(let block)? = values["[\(language)]"], let found = block[key] { return found }
        return Self.languageDefaults[language]?[key]
    }

    /// Returns a setting's value (for that language's files, when `language` is given), or the default its spec
    /// declares.
    func value(_ key: String, language: String? = nil) -> JSONValue? {
        if let language, let found = own(key, language) { return found }
        if let found = values[key] { return found }
        return app.extensions.specs[key]?.default
    }
    /// Reads a value by name, for a key that isn't declared here (a row of Settings, an extension's). Returns nil when
    /// the value isn't of that type.
    func string(_ key: String, language: String? = nil) -> String? { value(key, language: language)?.string }
    func bool(_ key: String, language: String? = nil) -> Bool? { value(key, language: language)?.bool }
    func number(_ key: String, language: String? = nil) -> Double? {
        guard let raw = value(key, language: language)?.number else { return nil }
        return clamped(key, raw)
    }
    /// Returns a declared setting's value (for `language`'s files when given): settings.json's value, else its default.
    package subscript<Value>(_ setting: Setting<Value>, language language: String? = nil) -> Value {
        setting.read(stored(setting.key, language))
    }
    /// Returns a number kept in its row's range. A value outside the range in settings.json counts as the nearest end.
    package subscript(_ setting: Setting<Double>, language language: String? = nil) -> Double {
        clamped(setting.key, setting.read(stored(setting.key, language)))
    }
    private func clamped(_ key: String, _ raw: Double) -> Double {
        app.extensions.specs[key]?.clamped(raw) ?? raw
    }
    private func stored(_ key: String, _ language: String?) -> JSONValue? {
        language.flatMap { own(key, $0) } ?? values[key]
    }
    /// Sets a declared setting, and nil goes back to the default.
    package func set<Value>(_ setting: Setting<Value>, _ value: Value?, language: String? = nil) {
        set(setting.key, value?.setting, language: language)
    }

    /// Whether a row's `requires` rule holds. "key" means the key is on (true, or a value that isn't empty, off, never
    /// or 0). The rule can also be "key=value" or "key!=value".
    func meets(_ rule: String?) -> Bool {
        guard let rule else { return true }
        func text(_ key: String) -> String { value(key).map(ExtActions.text) ?? "" }
        if let range = rule.range(of: "!=") {
            return text(String(rule[..<range.lowerBound])) != rule[range.upperBound...]
        }
        if let range = rule.range(of: "=") {
            return text(String(rule[..<range.lowerBound])) == rule[range.upperBound...]
        }
        return !["", "false", "off", "never", "0"].contains(text(rule))
    }

    /// Sets the key in `language`'s own block, whether the block had the key or not (for the language picker in
    /// Settings, and the editor's status bar card for code suggestions). A nil `value` takes the key out.
    package func setOwn(_ key: String, _ value: JSONValue?, language: String) {
        var block: [String: JSONValue] = [:]
        if case .object(let existing)? = values["[\(language)]"] { block = existing }
        block[key] = value
        set("[\(language)]", block.isEmpty ? nil : .object(block))
    }

    /// The languages settings.json has a block for.
    var languagesSet: [String] {
        values.keys.filter { $0.hasPrefix("[") && $0.hasSuffix("]") }.map { String($0.dropFirst().dropLast()) }.sorted()
    }

    /// Shows a value without saving it (when the palette tries themes on). `set` keeps a value, and
    /// `preview(key, saved)` goes back.
    func preview(_ key: String, _ value: JSONValue?) {
        var next = values
        next[key] = value
        apply(next)
    }

    /// Sets a value. With `language`, a value that language has of its own is changed in its block, where it's read.
    /// Any other value changes for all files.
    package func set(_ key: String, _ value: JSONValue?, language: String? = nil) {
        if let language, own(key, language) != nil { return setOwn(key, value, language: language) }
        var next = values
        next[key] = value
        apply(next)   // applied at once, and the daemon's echo confirms it
        inFlight[key, default: 0] += 1
        lastSet = Task { [lastSet] in
            await lastSet?.value
            let error = await app.tryCall(SettingsSet(key: key, value: value)).error
            inFlight[key] = inFlight[key].flatMap { $0 > 1 ? $0 - 1 : nil }
            // If it wasn't saved, say so and show what settings.json really holds, instead of a value that reverts
            // later.
            if let error {
                Banner.show(String(localized: "Couldn’t change “\(key)”: \(error)"), style: .error)
                await load()
            }
        }
    }
}
