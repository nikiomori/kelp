import Testing

@testable import KelpKit

/// The sidebar finds a row by key, by the screen it stands for and by the chat it holds as a logo from an index made
/// with the tree. Where two rows match, the one higher up wins, as a walk from the top found it.
@MainActor @Test func theSidebarFindsTheRowAWalkFromTheTopWould() {
    typealias Node = SidebarController.Node
    let project = Node(.project("p")), own = Node(.workspace("w")), other = Node(.workspace("v"))
    project.workspace = "w"
    project.hidden = ["x"]
    let chat = Node(.agent("a")), again = Node(.agent("a")), alsoHolds = Node(.project("q"))
    alsoHolds.workspace = "w"
    alsoHolds.hidden = ["x"]
    other.children = [chat]
    project.children = [own, other]
    let index = SidebarController.NodeIndex([project, again, alsoHolds])
    #expect(index.byKey["a:a"] === chat && index.byKey["w:v"] === other && index.byKey["p:p"] === project)
    #expect(index.standingFor["w"] === project && index.holding["x"] === project)
    #expect(index.byKey["a:missing"] == nil && index.holding["y"] == nil)
}
