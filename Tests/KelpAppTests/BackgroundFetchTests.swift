import AppKit
import Core
import Foundation
import GitKit
import TestSupport
import Testing

@testable import BuiltinGit
@testable import KelpApp
@testable import KelpKit

/// Kelp's background fetch, against a real daemon and a real remote: what it brings, how a failure shows, and when it
/// holds back.
extension AppOfItsOwn {
    /// A remote another clone pushed to, with the rig's main branch on it.
    private func remote(_ rig: AppRig) throws -> (bare: String, other: String) {
        let bare = tmp().path, other = tmp().path
        try Git.run(["init", "-q", "--bare", "-b", "main"], cwd: bare, remotes: .none)
        try rig.git("remote", "add", "origin", bare)
        try rig.git("push", "-q", "-u", "origin", "main")
        try Git.run(["clone", "-q", bare, other], cwd: tmp().path, remotes: .none)
        for args in [["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "theirs"]] {
            try Git.run(args, cwd: other, remotes: .none)
        }
        try Git.run(["push", "-q"], cwd: other, remotes: .none)
        return (bare, other)
    }

    @Test func aBackgroundFetchBringsTheCountsAndFailsQuietly() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        _ = try remote(rig)
        let fetch = BackgroundFetch.of(rig.app), wid = rig.workspace.id
        var now = Date()
        fetch.clock = { now }
        await fetch.pass()
        #expect(try await rig.client.call(GitBranches(id: wid)).behind == 1)   // the chip's ↓1, without a click
        #expect(fetch.trouble(wid) == nil && fetch.chip(wid) == nil)

        try rig.git("remote", "set-url", "origin", "https://nonexistent.invalid/r.git")
        await fetch.pass()   // not five minutes yet: nothing runs
        #expect(fetch.trouble(wid) == nil)
        now += BackgroundFetch.every
        await fetch.pass()
        #expect(fetch.trouble(wid)?.kind == .offline)
        // A word in the popover's line and the chip's tooltip, no mark yet.
        let chip = try #require(fetch.chip(wid))
        #expect(chip.said.hasSuffix("— offline") && chip.said.hasPrefix("fetched") && chip.mark == nil, "\(chip)")
        let popover = SyncPopover(app: rig.app, worktree: wid)
        rig.show(popover, 320, 400)
        popover.update()
        #expect(popover.state.stringValue.hasSuffix(" · offline"), "\(popover.state.stringValue)")
        // After an hour of failures, the grey mark at the chip's end.
        now += BackgroundFetch.markAfter
        await fetch.pass()
        #expect(fetch.chip(wid)?.mark == "wifi.slash")
        // Off in Settings: nothing of it shows, and nothing runs.
        rig.app.settings.set(SettingKeys.fetchInBackground, false)
        now += BackgroundFetch.every
        await fetch.pass()
        #expect(fetch.trouble(wid) == nil)
    }

    /// A remote that wants a sign-in isn't asked every five minutes: the background waits for a fetch by hand.
    @Test func aSignInWaitsForAFetchByHand() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        let (bare, _) = try remote(rig), fetch = BackgroundFetch.of(rig.app), wid = rig.workspace.id
        var now = Date()
        fetch.clock = { now }
        // ssh that a key can't get into, as git@ hosts answer.
        try rig.git(
            "config", "core.sshCommand",
            "sh -c 'echo \"git@example.com: Permission denied (publickey).\" >&2; exit 255' --")
        try rig.git("remote", "set-url", "origin", "git@example.com:o/r.git")
        await fetch.pass()
        #expect(fetch.trouble(wid)?.kind == .signIn && fetch.trouble(wid)?.host == "example.com")
        #expect(
            BackgroundFetch.words(try #require(fetch.trouble(wid)), inPopover: true)
                == "example.com wants a sign-in, press Fetch")
        try rig.git("remote", "set-url", "origin", bare)   // the sign-in fixed elsewhere
        now += BackgroundFetch.every
        await fetch.pass()
        #expect(fetch.trouble(wid)?.kind == .signIn)   // not asked again
        #expect(await GitSync.run(rig.app, wid, [.fetch]) == nil)
        #expect(fetch.trouble(wid) == nil)
    }

    /// A project with a pull or push under way is left alone, and a pull by hand waits for a background fetch that
    /// runs.
    @Test func aBackgroundFetchKeepsOutOfAPullsWay() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        _ = try remote(rig)
        let fetch = BackgroundFetch.of(rig.app), wid = rig.workspace.id
        GitSync.state(rig.app).running[wid] = .init(title: "Pulling…", op: .pull)
        await fetch.pass()
        #expect(try await rig.client.call(GitBranches(id: wid)).behind == 0)
        GitSync.state(rig.app).running[wid] = nil

        try rig.git(
            "config", "core.sshCommand",
            "sh -c 'sleep 1; echo \"ssh: Could not resolve hostname example.com\" >&2; exit 255' --")
        try rig.git("remote", "set-url", "origin", "git@example.com:o/r.git")
        let background = Task { await fetch.pass() }
        #expect(try await waitFor { !fetch.running.isEmpty })
        await fetch.settle(wid)
        #expect(fetch.trouble(wid)?.kind == .offline)   // it ended before settle returned
        await background.value
    }

    /// The branch chip says it too: the reason in its tooltip, and the mark after an hour.
    @Test func theBranchChipShowsAFetchThatFails() async throws {
        let rig = try await AppRig()
        defer { rig.done() }
        _ = try remote(rig)
        rig.app.extensions.reload()
        let fetch = BackgroundFetch.of(rig.app), wid = rig.workspace.id
        var now = Date()
        fetch.clock = { now }
        await fetch.pass()   // one that works, for the tooltip's "fetched … ago"
        try rig.git("remote", "set-url", "origin", "https://nonexistent.invalid/r.git")
        now += BackgroundFetch.every
        await fetch.pass()
        let info = BranchInfo(
            current: "main", head: "abc1234", local: ["main"], remote: ["origin/main"], upstream: "origin/main",
            ahead: 2, behind: 0, merging: false)
        rig.app.land(GitEvent(worktree: rig.app.gitKey(wid), branches: info))
        rig.app.workbench.mainWorkspaceId = wid   // as the editor area on screen sets it
        let bar = WindowBar(app: rig.app)
        @MainActor func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        @MainActor func chip() throws -> NSButton {
            try #require(all(bar).compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix("main") == true })
        }
        @MainActor func marks() throws -> Int {
            let title = try chip().attributedTitle
            var count = 0
            title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { v, _, _ in
                if v != nil { count += 1 }
            }
            return count
        }
        #expect(try chip().toolTip?.contains(" · fetched") == true)
        let tip = try chip().toolTip ?? ""
        #expect(tip.hasSuffix("— offline"), "\(tip)")
        let before = try marks()
        now += BackgroundFetch.markAfter + BackgroundFetch.every
        await fetch.pass()
        #expect(try await waitFor { (try? marks()) == before + 1 })
    }
}
