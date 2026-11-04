import AppKit
import Carbon.HIToolbox
import Core

/// Chats outside any project: "No Project", the first row of the sidebar, over a folder of Kelp's own (~/.kelp/scratch)
/// where each agent gets a folder of its own for its task. A quick question, a one-off script, something in Downloads.
/// ⌃⌥⌘K from any app starts one in the main window.
@MainActor
final class NoProject: NSObject {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init() }
    private var hotKey: EventHotKeyRef?

    /// Its project's path, so lists of projects can tell it apart.
    static var path: String { URL(fileURLWithPath: Paths.scratch.path).resolvingSymlinksInPath().path }
    static func holds(_ r: Repo?) -> Bool { r.map { holds(path: $0.path) } ?? false }
    static func holds(path p: String) -> Bool { URL(fileURLWithPath: p).resolvingSymlinksInPath().path == path }

    /// Made the first time (the daemon's), so the row is there before anyone asks.
    func ensure() async {
        guard !app.repos.contains(where: Self.holds), await app.quiet(ScratchEnsure()) != nil else { return }
        await app.refresh()
    }

    /// A new chat on it, in the main window, from wherever you are.
    func newChat() {
        NSApp.activate()
        app.workbench.bringToFront()
        Task {
            await ensure()
            if let r = app.repos.first(where: Self.holds) { app.workbench.newChat(repo: r.id) }
        }
    }

    /// One already working in a folder you pick (Downloads, a game, photos): the folder stays as it is, not a project.
    func newChat(inFolderOf r: Repo) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.prompt = String(localized: "Start Chat")
        p.message = String(localized: "The agent works in this folder. It isn't added as a project.")
        Task {
            guard await runSheet(p) == .OK, let url = p.url else { return }
            app.workbench.newChat(repo: r.id, cwd: url.path)
        }
    }

    /// ⌃⌥⌘K from anywhere (a Carbon hot key: no Accessibility permission needed).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler is a C function: it finds this object through the pointer it's handed (the app keeps it).
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            guard let me else { return noErr }
            let np = Unmanaged<NoProject>.fromOpaque(me).takeUnretainedValue()
            DispatchQueue.main.async { np.newChat() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4B524C4C), id: 1)   // 'KRLL'
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
