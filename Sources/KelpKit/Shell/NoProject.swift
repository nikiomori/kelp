import AppKit
import Carbon.HIToolbox
import Core
import DesignKit

/// Chats outside any project. They sit under "Chats", the last row of the sidebar, over a folder of Kelp's own
/// (~/.kelp/scratch) where each agent gets a folder of its own for its task: a quick question, a one-off script,
/// something in Downloads. ⌃⌥⌘K from any app starts one in the main window.
@MainActor
final class NoProject: NSObject {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init()
    }
    private var hotKey: EventHotKeyRef?

    /// The path of the No Project project, so lists of projects can tell it apart.
    static var path: String { resolved(Paths.scratch.path) }
    static func holds(_ repo: Repo?) -> Bool { repo.map { holds(path: $0.path) } ?? false }
    static func holds(path candidate: String) -> Bool { resolved(candidate) == path }
    /// Each path without its symlinks, asked of the disk once. Every project's name asks whether it's this project, for
    /// every row and tile drawn, and two walks of the disk each time held the main thread through a sidebar's pass.
    private static var resolvedPaths: [String: String] = [:]
    private static func resolved(_ path: String) -> String {
        if let known = resolvedPaths[path] { return known }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        resolvedPaths[path] = real
        return real
    }

    /// Makes the daemon's No Project project the first time, so the row is there before anyone asks.
    func ensure() async {
        if !app.repos.contains(where: Self.holds) { _ = await app.quiet(ScratchEnsure()) }
    }

    /// Starts a new chat with no project, in the main window, from wherever you are.
    func newChat() {
        NSApp.activate()
        app.workbench.bringToFront()
        Task {
            await ensure()
            if let repo = app.repos.first(where: Self.holds) { app.workbench.newChat(repo: repo.id) }
        }
    }

    /// Starts a chat already working in a folder you pick (Downloads, a game, photos). The folder stays as it is and
    /// doesn't become a project.
    func newChat(inFolderOf repo: Repo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Start Chat")
        panel.message = String(localized: "The agent works in this folder. It isn’t added as a project.")
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            app.workbench.newChat(repo: repo.id, cwd: url.path)
        }
    }

    /// Registers ⌃⌥⌘K from anywhere (a Carbon hot key, so no Accessibility permission is needed).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler is a C function, so it finds this object through the pointer it's handed (the app keeps the
        // object alive).
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, me in
                // Other hot keys of Kelp's (Quick Entry's ⌃⌥Space) come to the same target: only ours is taken.
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard let me, id.signature == OSType(0x4B524C4C) else { return OSStatus(eventNotHandledErr) }
                let np = Unmanaged<NoProject>.fromOpaque(me).takeUnretainedValue()
                DispatchQueue.main.async { np.newChat() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4B524C4C), id: 1)   // 'KRLL'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
