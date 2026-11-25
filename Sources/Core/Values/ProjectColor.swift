/// The colours a project can be given in the menu on its row: `IconTile`'s own hues and two more. None is orange or
/// red, because beside a row's marks those mean asking and failed. They are kept by name in UIState, and a colour a
/// later build dropped reads as none.
package enum ProjectColor: String, CaseIterable {
    case blue, indigo, purple, pink, teal, yellow, brown

    package static let key = "sidebar.colors"

    package var ink: (dark: Int, light: Int) {
        switch self {
        case .blue: (0x6CB4FF, 0x0058B8)
        case .indigo: (0x9E9CFF, 0x4440C0)
        case .purple: (0xD59CFF, 0x8A2BB0)
        case .pink: (0xF49AC1, 0xA8246A)
        case .teal: (0x5BD6E6, 0x006473)
        case .yellow: (0xE6C75A, 0x6E5400)
        case .brown: (0xD2AE88, 0x7A5230)
        }
    }

    /// Returns the colours as `uiState` keeps them, as id → name.
    package static func value(_ colors: [String: ProjectColor]) -> JSONValue {
        .object(colors.mapValues { .string($0.rawValue) })
    }
    package static func read(_ json: JSONValue?) -> [String: ProjectColor] {
        guard case .object(let object)? = json else { return [:] }
        return object.compactMapValues { $0.string.flatMap(ProjectColor.init) }
    }
}
