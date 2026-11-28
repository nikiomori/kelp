import AppKit
import Testing

@testable import KelpKit

/// Recording a shortcut takes only the keys typed in Settings: a key for another window goes there and ends the
/// recording, and so does Settings stop being key. Neither window is ever shown.
@MainActor
struct KeyRecorderTests {
    let settings = window(), editor = window()

    @Test func aKeyTypedInSettingsIsTheShortcut() {
        var keys: [String] = [], ended = false
        let recorder = KeyRecorder(in: settings, key: { keys.append($0.characters ?? "") }, ended: { ended = true })
        defer { recorder.stop() }
        #expect(recorder.handle(save(in: settings)) == nil)
        #expect(keys == ["s"])
        #expect(!ended)
    }

    @Test func aKeyForAnotherWindowGoesThereAndEndsRecording() {
        var keys: [String] = [], ended = false
        let recorder = KeyRecorder(in: settings, key: { keys.append($0.characters ?? "") }, ended: { ended = true })
        defer { recorder.stop() }
        let ev = save(in: editor)
        #expect(recorder.handle(ev) === ev)
        #expect(keys.isEmpty)
        #expect(ended)
    }

    @Test func settingsResigningKeyEndsRecording() {
        var ended = false
        let recorder = KeyRecorder(in: settings, key: { _ in }, ended: { ended = true })
        defer { recorder.stop() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: editor)
        #expect(!ended)   // another window's focus is not Settings'
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        #expect(ended)
    }
}

/// A window with its number, never ordered in.
@MainActor
private func window() -> NSWindow {
    NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: false)
}

@MainActor
private func save(in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
}
