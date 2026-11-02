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

@Test func aHostsPortIsSaidAsItIsReachedHere() {
    let waiting = PortsList.Port(port: 8000, pid: 7, command: "uvicorn", session: "", host: "devbox")
    var p = ServedPage(waiting)
    #expect(!p.forwarded && p.address == "localhost:8000" && p.place == "devbox:8000")
    p.moved(to: 8001)
    #expect(p.forwarded && p.url == "http://localhost:8001" && p.place == "devbox:8000 → :8001")
    // A run's printed page was forwarded to 5174: that address, knowing it's the host's 5173, and one entry for both.
    let run = PortsList.Port(port: 5173, pid: 7, command: "node", session: "s", host: "devbox", here: 5174)
    let pages = ServedPages.list(printed: ["http://localhost:5174/app"], ports: [run])
    #expect(pages.count == 1 && pages[0].url == "http://localhost:5174/app" && pages[0].remotePort == 5173 && pages[0].forwarded)
    // By hand: no process to stop. The connection gone: dimmed, and still there.
    let manual = PortsList.Port(port: 5432, pid: 0, command: "db.internal:5432", session: "", host: "devbox", here: 5433, offline: true)
    #expect(ServedPage(manual).pid == nil && ServedPage(manual).offline && ServedPage(manual).place == "devbox:5432 → :5433")
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
