import AppKit

/// How a table's columns look: their widths, the ones hidden, and the order its rows are read in. The tab keeps it per
/// database and table (`DatabaseTab.keepLook`), so a table opened again looks as it was left.
struct ColumnsLook: Codable, Equatable {
    struct Order: Codable, Equatable {
        var column: String, ascending: Bool
    }
    var widths: [String: Double] = [:]
    var hidden: [String] = []
    var orders: [Order] = []
}

extension ResultGrid {
    var look: ColumnsLook {
        var look = ColumnsLook(orders: orders.map { .init(column: $0.column, ascending: $0.ascending) })
        for (name, column) in named {
            look.widths[name] = Double(column.width)
            if column.isHidden { look.hidden.append(name) }
        }
        return look
    }

    /// Gives the columns the widths `look` has for them, and hides the ones it hid. A column it doesn't know keeps
    /// the width it was given.
    func apply(_ look: ColumnsLook) {
        for (name, column) in named {
            if let width = look.widths[name] { column.width = CGFloat(width) }
            column.isHidden = look.hidden.contains(name)
        }
    }

    /// The result's columns by name, without the rows' numbers.
    private var named: [(String, NSTableColumn)] {
        table.tableColumns.compactMap { column in
            Int(column.identifier.rawValue).flatMap { columns.indices.contains($0) ? (columns[$0], column) : nil }
        }
    }
}
