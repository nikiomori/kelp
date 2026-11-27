import AppKit

extension NSMenu {
    /// Every item that does something, each with the items whose submenus lead to it, outermost first. The system's
    /// Services are left out: they are other apps' actions, not Kelp's commands.
    @MainActor func leaves() -> [(item: NSMenuItem, path: [NSMenuItem])] {
        items.filter { !$0.isSeparatorItem }.flatMap { item -> [(item: NSMenuItem, path: [NSMenuItem])] in
            guard let submenu = item.submenu else { return [(item, [])] }
            guard submenu !== NSApp.servicesMenu else { return [] }
            return submenu.leaves().map { ($0.item, [item] + $0.path) }
        }
    }
}
