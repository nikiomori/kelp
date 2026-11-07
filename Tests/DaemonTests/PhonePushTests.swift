import Core
import Foundation
import Testing

@testable import Daemon

@Test func onlyAnHttpAddressIsAChannel() {
    #expect(PhonePush.url("https://ntfy.sh/kelp-abc")?.host == "ntfy.sh")
    #expect(PhonePush.url(" http://10.0.0.1/t ") != nil)
    #expect(PhonePush.url("") == nil)
    #expect(PhonePush.url("ntfy.sh/topic") == nil)
    #expect(PhonePush.url("file:///etc/passwd") == nil)
    #expect(PhonePush.url(nil) == nil)
}

@Test func whatStandsStillIsWorthTelling() {
    #expect(PhonePush.worthTelling(Session(cwd: "/", command: "x", status: .waiting)))
    #expect(PhonePush.worthTelling(Session(cwd: "/", command: "x", status: .error)))
    #expect(!PhonePush.worthTelling(Session(cwd: "/", command: "x", status: .done)))
    #expect(!PhonePush.worthTelling(Session(cwd: "/", command: "x", status: .working)))
}

@Test func aMessageLeavesOutWhatTheAgentSaidUnlessAsked() {
    let s = Session(cwd: "/", command: "x", status: .waiting, summary: "Allow rm -rf build?")
    #expect(PhonePush.message(s, name: "Codex", place: "api", details: false) == ("Codex needs you", "api"))
    #expect(PhonePush.message(s, name: "Codex", place: "api", details: true).body == "api: Allow rm -rf build?")
}

@Test func aMuteCountsUntilItsDate() {
    let now = Date()
    let mutes = JSONValue.object([
        "w": .double(now.timeIntervalSince1970 + 60), "old": .double(now.timeIntervalSince1970 - 60)
    ])
    #expect(PhonePush.muted(mutes, ["s", "w"], now: now))
    #expect(!PhonePush.muted(mutes, ["old", nil], now: now))
    #expect(!PhonePush.muted(nil, ["w"], now: now))
}

@Test func theTitleGoesInTheQuerySoAnyTextFits() throws {
    let url = try #require(URL(string: "https://ntfy.sh/t"))
    let r = try #require(PhonePush.request(url, title: "Клод needs you", body: "api"))
    #expect(r.httpMethod == "POST")
    #expect(r.httpBody == Data("api".utf8))
    #expect(r.url?.query?.contains("title=") == true)
}
