// The sidebar's foot that holds the plan limits (`UsageView`), its right-click menu, and its sample in Settings.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The plan limits at the foot of the sidebar. A right-click on them sets what they show.
final class UsageFooter: NSHostingView<UsageView> {
    var app: AppModel?
    static func make(_ app: AppModel) -> UsageFooter {
        let footer = UsageFooter(rootView: UsageView(app: app))
        footer.app = app
        footer.sizingOptions = [.intrinsicContentSize]
        return footer
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let app else { return nil }
        let menu = NSMenu()
        menu.addChoices(SettingKeys.usageLimits, app, heading: String(localized: "Show"))
        menu.addToggle(SettingKeys.usageResets, app, title: String(localized: "Reset Time"))
        menu.addToggle(SettingKeys.usagePace, app, title: String(localized: "Pace Mark"))
        addAgents(to: menu, app)
        menu.addItem(.separator())
        menu.add(String(localized: "Open Usage")) { app.extensions.run("agents.usage") }
        menu.addChoiceMenu(SettingKeys.alertAt, app, title: String(localized: "Warn At"), tryOn: false)
        menu.addItem(.separator())
        menu.add(String(localized: "Hide Plan Limits")) {
            app.settings.set(SettingKeys.readPlans, false)
            Banner.show(String(localized: "Plan limits are hidden. Settings › Agents brings them back."))
        }
        menu.addSettingsLink(String(localized: "Limits Settings…"), section: "agents", group: "Plan limits", app)
        return menu
    }
}

extension UsageFooter {
    /// Adds the agents that have used their plans, each checked while it has a row in the foot. Unchecking one hides
    /// it; the last one shown can't be unchecked (Hide Plan Limits hides the foot).
    private func addAgents(to menu: NSMenu, _ app: AppModel) {
        let rows = UsageView.rows(app).filter { ($0.main?.used ?? 0) > 0 }
        guard rows.count > 1 else { return }
        let hidden = app.settings[SettingKeys.usageHiddenAgents]
        let shown = UsageView.visible(rows, hidden: hidden).map(\.id)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Agents")))
        for row in rows {
            let on = shown.contains(row.id)
            let item = menu.add(row.name) {
                app.settings.set(
                    SettingKeys.usageHiddenAgents, on ? hidden + [row.id] : hidden.filter { $0 != row.id })
            }
            item.state = on ? .on : .off
            if on, shown.count == 1 { item.action = nil }   // the menu greys an item without an action
        }
    }
}

/// A live sample of the sidebar's foot for Settings, with this Mac's readings. The settings rows below it change it as
/// they are switched. It leaves out the divider above the foot, which belongs to the sidebar's edge rather than the
/// foot. It is as wide as the row and sits on the card as the rows do, because a grey plate of its own read as a box
/// inside the box.
struct LimitsSample: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        UsageView(app: app, ruled: false).frame(maxWidth: .infinity)
    }
}
