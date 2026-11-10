import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import BuiltinFiles
@testable import KelpKit

extension AppOfItsOwn {
    /// "Changed on disk" asks about one version. An agent saves another while the sheet is up: Keep Mine writes only
    /// over the one it showed, so the newer one stays on disk and is asked about in its turn.
    @Test func keepMineWritesOnlyOverTheVersionItsSheetShowed() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let dir = testHome + "/keep-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = dir + "/notes.txt"
        try "one\n".write(toFile: p, atomically: true, encoding: .utf8)
        let tab = FileTab(uri: TabURI.file(p), app: rig.app)
        await tab.loading?.value
        let holder = NSViewController()
        holder.view = tab.view
        rig.show(holder, 400, 300)
        let window = try #require(tab.view.window)
        window.orderFrontRegardless()   // a window never on screen gets no sheet
        defer { window.orderOut(nil) }
        tab.editor?.setText("mine\n")
        tab.editor?.onChange?("mine\n")
        try "theirs\n".write(toFile: p, atomically: true, encoding: .utf8)
        #expect(try await waitFor(10) { window.attachedSheet != nil && tab.known?.text == "theirs\n" })
        let asked = try #require(window.attachedSheet)
        try "theirs, later\n".write(toFile: p, atomically: true, encoding: .utf8)
        #expect(try await waitFor(10) { tab.known?.text == "theirs, later\n" })   // read while the sheet is up
        window.endSheet(asked, returnCode: .alertFirstButtonReturn)   // Keep Mine
        // The daemon refuses the write and the tab asks again: that new sheet says the write was judged.
        #expect(try await waitFor(10) { window.attachedSheet.map { $0 !== asked } ?? false })
        #expect(try String(contentsOfFile: p, encoding: .utf8) == "theirs, later\n")
        #expect(tab.editor?.text == "mine\n" && tab.isEdited)
        if let again = window.attachedSheet { window.endSheet(again, returnCode: .alertSecondButtonReturn) }
    }
}
