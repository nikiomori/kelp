import Core
import Foundation
import Testing
import WorkbenchKit

private func port(_ n: Int, _ command: String = "node", pid: Int32 = 7) -> PortsList.Port {
    PortsList.Port(port: n, pid: pid, command: command, session: "s")
}

@Test func aRunsPrintedAddressComesFirstAndItsPortOnce() {
    let pages = ServedPages.list(printed: ["http://localhost:5173/app/"], ports: [port(3001), port(5173, pid: 9)])
    #expect(pages.map(\.port) == [5173, 3001])
    #expect(pages[0].url == "http://localhost:5173/app/")   // as printed, not the bare port
    #expect(pages[0].pid == 9)
    #expect(pages[1].url == "http://localhost:3001")
}

@Test func helpersAndForwardingsAreNotServers() {
    #expect(ServedPages.list(printed: [], ports: [port(51849, "agy"), port(5173, "ssh")]).isEmpty)
    // Printed by a run, it's meant to be opened whatever its number. On a host nothing here listens: no process to stop.
    let printed = ServedPages.list(printed: ["http://localhost:51000"], ports: [])
    #expect(printed.map(\.port) == [51000])
    #expect(printed[0].pid == nil)
}

@Test func aDatabaseGoesAfterThePagesAndIsNoPage() {
    let pages = ServedPages.list(printed: [], ports: [port(4000, "postgres"), port(5432, "docker"), port(8000)])
    #expect(pages.map(\.port) == [8000, 4000, 5432])
    #expect(pages.map(\.isWeb) == [true, false, false])
}

@Test func aLocalServersBareAddressFindsItsTabWhereverItWent() {
    var l = WorkspaceLayout()
    _ = l.add("file:///a")
    let cart = l.add("http://localhost:5173/cart")
    #expect(l.pageTab(for: "http://localhost:5173")?.id == cart.id)
    #expect(l.pageTab(for: "http://localhost:5173/")?.id == cart.id)
    #expect(l.pageTab(for: "http://localhost:5173/other") == nil)   // a link to another page is that page
    #expect(l.pageTab(for: "http://localhost:3000") == nil)
    #expect(l.pageTab(for: "file:///a") == nil)                     // a file keeps its own rules
    let site = l.add("https://example.com/a")
    #expect(l.pageTab(for: "https://example.com/a")?.id == site.id)
    #expect(l.pageTab(for: "https://example.com") == nil)           // only a local server is one site
}
