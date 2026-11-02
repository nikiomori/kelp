import Foundation
import Observation
import Core

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
        if let o = await app.call(SettingsGet()) { received(o) }   // else a banner: what's shown may not be settings.json
    }

    /// The daemon's settings (its event, or a load): a key still being set here keeps the value set here.
    func received(_ o: [String: JSONValue]) {
        var o = o
        for k in inFlight.keys { o[k] = values[k] }
        apply(o)
    }

    func apply(_ o: [String: JSONValue]) {
        guard o != values else { return }
        // The skills only depend on their switches: don't rewrite their files (on main) for every other setting.
        let skills = { (d: [String: JSONValue]) in d.filter { $0.key.hasPrefix("agents.skills.") } }
        let skillsChanged = values.isEmpty || skills(o) != skills(values)
        values = o
        app.themes.apply()
        if skillsChanged { AgentSkills.write(app) }
        if !app.extensions.extensions.isEmpty, ExtensionRegistry.disabled(o["extensions.disabled"]) != app.extensions.disabledLoaded {
            app.extensions.reload()
        }
    }

    /// A setting's value, or the default its spec declares.
    func value(_ key: String) -> JSONValue? {
        if let v = values[key] { return v }
        for s in app.extensions.all.settings { if let spec = s.specs.first(where: { $0.key == key }) { return spec.default } }
        return nil
    }
    package func string(_ key: String) -> String? { value(key)?.string }
    package func bool(_ key: String) -> Bool? { value(key)?.bool }
    package func number(_ key: String) -> Double? {
        guard let n = value(key)?.number else { return nil }
        return app.extensions.all.settings.lazy.flatMap(\.specs).first { $0.key == key }?.clamped(n) ?? n
    }

    /// Shows a value without saving it (the palette trying themes on); `set` keeps one, `preview(key, saved)` goes back.
    func preview(_ key: String, _ v: JSONValue?) {
        var next = values; next[key] = v
        apply(next)
    }

    package func set(_ key: String, _ v: JSONValue?) {
        var next = values; next[key] = v
        apply(next)   // optimistic; the daemon's echo confirms
        inFlight[key, default: 0] += 1
        lastSet = Task { [lastSet] in
            await lastSet?.value
            let error = await app.tryCall(SettingsSet(key: key, value: v)).error
            inFlight[key] = inFlight[key].flatMap { $0 > 1 ? $0 - 1 : nil }
            // Not saved: say so and show what settings.json really holds again, instead of a value that reverts later.
            if let error {
                Banner.show(String(localized: "Couldn't change “\(key)”: \(error)"), style: .error)
                await load()
            }
        }
    }
}
