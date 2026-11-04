import AppKit
import Carbon.HIToolbox
import Core

/// Agents and terminals outside any project: a floating window over a folder of their own (~/.kelp/scratch), for a
/// quick question or a one-off script. Window › Scratch, or ⌃⌥⌘K from any app. It isn't listed with the projects.
@MainActor
final class ScratchWindow: NSObject, NSWindowDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init() }
    private var panel: NSPanel?
    private var area: EditorArea?
    private var hotKey: EventHotKeyRef?

    /// Its unsaved files (a file opened from a scratch terminal): quitting and Save All count them too.
    var editedFiles: [SavableTab] { area?.editedFiles ?? [] }

    /// The scratch project's path, so lists of projects can leave it out.
    static var path: String { URL(fileURLWithPath: Paths.scratch.path).resolvingSymlinksInPath().path }
    static func isScratch(_ r: Repo?) -> Bool { r.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path } ?? false }

    func toggle() {
        if let p = panel, p.isVisible, p.isKeyWindow { p.orderOut(nil); return }
        Task { await show() }
    }

    private var opening = false
    private func show() async {
        guard !opening else { return }   // ⌃⌥⌘K twice while the first is still setting up: one panel
        opening = true; defer { opening = false }
        if panel == nil {
            guard let w = await app.call(ScratchEnsure()) else { return }   // the banner says why
            await app.refresh()
            let a = EditorArea(app: app, workspaceId: w.id)
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = String(localized: "Scratch")
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.isReleasedWhenClosed = false
            p.animationBehavior = .utilityWindow   // it comes and goes with one key: the system's fade, not a cut
            p.delegate = self
            p.contentViewController = a   // (the window takes the controller's empty view's size: set it after)
            p.minSize = NSSize(width: 420, height: 240)
            p.setContentSize(NSSize(width: 760, height: 480))
            p.setFrameAutosaveName("scratch"); if p.frame.origin == .zero { p.center() }
            panel = p; area = a
        }
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
        area?.reconcile()
        if area?.layout.allTabs.isEmpty == true { area?.newAgent() } else { area?.focusSelected() }
    }

    /// ⌃⌥⌘K from anywhere (a Carbon hot key: no Accessibility permission needed).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler is a C function: it finds this window through the pointer it's handed (the app keeps the window).
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            guard let me else { return noErr }
            let scratch = Unmanaged<ScratchWindow>.fromOpaque(me).takeUnretainedValue()
            DispatchQueue.main.async { scratch.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4B524C4C), id: 1)   // 'KRLL'
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
