import AppKit
import Core

/// A setting as menu items, worded as Settings words it: how a part of the window looks, changed on the part itself.
/// Pointing at a choice shows it (`tryOn`), a click keeps it, leaving goes back; what starts work (a check that asks
/// GitHub) only acts on the click.
@MainActor
extension NSMenu {
    /// The choices in place, under `heading`.
    package func addChoices(_ key: String, _ app: AppModel, heading: String, tryOn: Bool = true) {
        addItem(.sectionHeader(title: heading))
        addChoiceItems(key, app, tryOn: tryOn)
    }

    /// The choices in a submenu of their own.
    func addChoiceMenu(_ key: String, _ app: AppModel, title: String, tryOn: Bool = true) {
        let list = NSMenu()
        list.addChoiceItems(key, app, tryOn: tryOn)
        setSubmenu(list, for: addItem(withTitle: title, action: nil, keyEquivalent: ""))
    }

    /// A switch: a check mark, and a click changes it.
    package func addToggle(_ key: String, _ app: AppModel, title: String) {
        let on = app.settings.bool(key) == true
        add(title) { app.settings.set(key, .bool(!on)) }.state = on ? .on : .off
    }

    /// The last item: the section of Settings this part's settings are in, and the group in it.
    package func addSettingsLink(_ title: String, section: String, group: String? = nil, _ app: AppModel) {
        add(title) {
            app.extensions.run(
                "workbench.openSettings", ["section": .string(section), "group": group.map(JSONValue.string) ?? .null])
        }
    }

    private func addChoiceItems(_ key: String, _ app: AppModel, tryOn: Bool) {
        guard let spec = app.extensions.all.settings.lazy.flatMap(\.specs).first(where: { $0.key == key }) else {
            return
        }
        let now = app.settings.string(key), preview = ChoicePreview(app.settings)
        if tryOn, delegate == nil { delegate = preview }
        for option in SettingRow.options(spec, app) {
            let keep = ClosureTarget { app.settings.set(key, .string(option)) }
            let item = ChoiceItem(
                key: key, value: .string(option), preview: preview, title: SettingRow.label(key, option, app))
            item.target = keep
            item.representedObject = keep
            item.action = #selector(ClosureTarget.fire)
            item.state = option == now ? .on : .off
            addItem(item)
        }
    }
}

/// One choice of a setting; holds the preview, as a menu only keeps its delegate weakly.
private final class ChoiceItem: NSMenuItem {
    let key: String, value: JSONValue, preview: ChoicePreview
    init(key: String, value: JSONValue, preview: ChoicePreview, title: String) {
        self.key = key
        self.value = value
        self.preview = preview
        super.init(title: title, action: nil, keyEquivalent: "")
    }
    required init(coder: NSCoder) { fatalError() }
}

/// Shows the choice under the pointer without saving it, and puts back what was there when it moves on.
@MainActor
private final class ChoicePreview: NSObject, NSMenuDelegate {
    private let store: SettingsStore
    private var trying: (key: String, saved: JSONValue?)?
    init(_ store: SettingsStore) { self.store = store }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { show(item as? ChoiceItem) }
    func menuDidClose(_ menu: NSMenu) { show(nil) }

    private func show(_ item: ChoiceItem?) {
        if let tried = trying { store.preview(tried.key, tried.saved) }
        trying = nil
        guard let item else { return }
        trying = (item.key, store.values[item.key])
        store.preview(item.key, item.value)
    }
}
