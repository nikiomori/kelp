import AppKit
import Core
import DesignKit

/// A setting as menu items, worded as Settings words it, so how a part of the window looks can be changed on the part
/// itself. Pointing at a choice shows it (`tryOn`), a click keeps it, and leaving goes back. A choice that starts work
/// (a check that asks GitHub) only acts on the click.
@MainActor
extension NSMenu {
    /// Adds the choices in this menu, under `heading`.
    package func addChoices(_ setting: Setting<String>, _ app: AppModel, heading: String, tryOn: Bool = true) {
        addItem(.sectionHeader(title: heading))
        addChoiceItems(setting, app, tryOn: tryOn)
    }

    /// Adds the choices in a submenu of their own.
    package func addChoiceMenu(_ setting: Setting<String>, _ app: AppModel, title: String, tryOn: Bool = true) {
        let list = NSMenu()
        list.addChoiceItems(setting, app, tryOn: tryOn)
        add(title, submenu: list)
    }

    /// Adds a switch, shown as a check mark that a click changes. The mark is read each time the menu opens, so it
    /// stays right in the menu bar, which is built once.
    package func addToggle(_ setting: Setting<Bool>, _ app: AppModel, title: String) {
        let target = ToggleTarget(setting, app.settings)
        let item = addItem(withTitle: title, action: #selector(ToggleTarget.flip), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.state = app.settings[setting] ? .on : .off
    }

    /// Adds the last item, which opens the section of Settings this part's settings are in, at their group.
    package func addSettingsLink(_ title: String, section: String, group: String? = nil, _ app: AppModel) {
        add(title) {
            app.extensions.run(
                "workbench.openSettings", ["section": .string(section), "group": group.map(JSONValue.string) ?? .null])
        }
    }

    private func addChoiceItems(_ setting: Setting<String>, _ app: AppModel, tryOn: Bool) {
        let key = setting.key
        guard let spec = app.extensions.specs[key] else { return }
        let now = app.settings[setting], preview = ChoicePreview(app.settings)
        if tryOn, delegate == nil { delegate = preview }
        for option in SettingRow.options(spec) {
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

/// A switch's menu item: a click flips the setting, and the item's mark follows it.
@MainActor
private final class ToggleTarget: NSObject, NSMenuItemValidation {
    let setting: Setting<Bool>, store: SettingsStore
    init(_ setting: Setting<Bool>, _ store: SettingsStore) {
        self.setting = setting
        self.store = store
    }
    @objc func flip() { store.set(setting, !store[setting]) }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = store[setting] ? .on : .off
        return true
    }
}

/// One choice of a setting. It holds the preview, because a menu only keeps its delegate weakly.
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
