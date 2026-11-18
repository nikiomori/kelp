import AppKit
import Testing

@testable import DesignKit

/// A page's column of lists (`SectionList`): a section folds on a click and opens again, an empty one says its note,
/// and a new reading leaves the chosen row chosen, whether its words changed or rows came and went around it.
@MainActor @Test func aSectionListFoldsAndKeepsTheChosenRow() {
    func row(_ id: String, _ trailing: String) -> SectionList.Row {
        var row = SectionList.Row(id: id, title: id)
        row.trailing = trailing
        return row
    }
    func sections(_ memory: String, extra: Bool = false) -> [SectionList.Section] {
        [
            .init(id: "agents", title: "Agents", rows: [], note: "No agents now."),
            .init(id: "boxes", title: "Containers", rows: (extra ? [row("new", "1 MB")] : []) + [row("web", memory)])
        ]
    }
    let lists = SectionList.Coordinator(), table = lists.table
    _ = table.plainList("s")
    table.dataSource = lists
    table.delegate = lists
    lists.show(sections("12 MB"))
    #expect(lists.lines.map(\.key) == ["s agents", "n No agents now.", "s boxes", "r web"])
    table.selectRowIndexes([3], byExtendingSelection: false)
    lists.show(sections("13 MB"))   // the same rows with new words
    #expect(table.selectedRow == 3)
    lists.show(sections("13 MB", extra: true))   // a row came in above it
    #expect(table.selectedRow == 4 && lists.lines.count == 5)
    lists.fold("boxes")
    #expect(lists.lines.map(\.key) == ["s agents", "n No agents now.", "s boxes"])
    lists.fold("boxes")
    #expect(lists.lines.count == 5)
    #expect(!lists.tableView(table, shouldSelectRow: 0) && lists.tableView(table, shouldSelectRow: 4))
}
