import AppKit
import Core

/// The colours a project can be given in its row's menu, as Finder's tags are: system colours, so they follow light and
/// dark. Kept by name in UIState (`SidebarController.colors`); one a later build dropped just reads as none.
enum ProjectColor: String, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink

    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        }
    }

    /// Its dot in the menu.
    var dot: NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { [color] r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.cacheMode = .never   // drawn again for each appearance
        return img
    }
}

extension SidebarController {
    /// The colour each project was given (its row's menu); the others stay grey.
    var colors: [String: ProjectColor] {
        get {
            guard case .object(let o)? = app.uiState["sidebar.colors"] else { return [:] }
            return o.compactMapValues { $0.string.flatMap(ProjectColor.init) }
        }
        set { app.uiState["sidebar.colors"] = .object(newValue.mapValues { .string($0.rawValue) }) }
    }
}
