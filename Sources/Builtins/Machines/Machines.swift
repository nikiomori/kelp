import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers
import WorkbenchKit

/// Kelp's virtual machines (Core/VM/VMs.swift) as the sidebar's Machines block and a machine's tab ("vm:<name>") see them.
@MainActor
enum Machines {
    /// Any Xcode, by any name (Xcode-beta.app, Xcode_27.1.app as CI names it): they share its bundle ID; Xcodes.app
    /// (which installs them) doesn't.
    private static var xcodeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") != nil
    }

    /// The kinds of machine the sidebar's Machines + offers; `missing` says what this Mac lacks for one (Apple silicon, an
    /// Android SDK, Xcode).
    static var machineChoices: [(title: String, image: String, missing: String?)] {
        #if arch(arm64)
            let silicon: String? = nil
        #else
            let silicon: String? = String(localized: "Needs a Mac with Apple silicon")
        #endif
        let sdk = AndroidSDK.avdmanager != nil && AndroidSDK.newestImage() != nil
        let xcode = Self.xcodeInstalled || ProcessInfo.processInfo.environment["DEVELOPER_DIR"] != nil
        return [
            (String(localized: "Linux (Debian 13)"), "debian-13", silicon),
            (String(localized: "macOS…"), "macos", silicon),
            (
                String(localized: "Android"), "android",
                sdk ? nil : String(localized: "Needs Android Studio's SDK with an arm64 system image")
            ),
            (String(localized: "iOS"), "ios", xcode ? nil : String(localized: "Needs Xcode with an iOS simulator"))
        ]
    }

    /// File › New Machine… (and Open Quickly's command): the kinds the sidebar's + offers, listed where the palette
    /// shows. One this Mac can't run says why and isn't made.
    static func chooseNew(_ app: AppModel) {
        let choices = machineChoices
        app.workbench.showList(
            String(localized: "New machine"), keys: String(localized: "↩ makes it · ⎋ closes")
        ) { typed in
            let text = typed.lowercased()
            func shown(_ title: String) -> Bool { text.isEmpty || title.lowercased().contains(text) }
            let kinds = choices.filter { shown($0.title) }.map { choice in
                QuickItem(
                    choice.title, detail: choice.missing ?? "",
                    icon: choice.image == "macos" ? "apple.logo" : choice.image == "ios" ? "iphone" : "shippingbox",
                    open: { choice.missing == nil ? newMachine(app, choice.image) : NSSound.beep() })
            }
            let fromFile = String(localized: "From a File…")
            guard shown(fromFile) else { return kinds }
            let file = QuickItem(
                fromFile,
                detail: String(localized: "macOS from a restore image (.ipsw), Linux from a cloud image's raw disk"),
                icon: "doc", open: { machineFromFile(app) })
            return kinds + [file]
        }
    }

    /// A machine from a file of the user's: macOS from its restore image, Linux from a cloud image's raw disk.
    static func machineFromFile(_ app: AppModel) {
        Task {
            let panel = NSOpenPanel()
            panel.message = String(
                localized: "A macOS restore image (.ipsw) or a Linux cloud image's raw disk (.raw, .img)")
            panel.allowedContentTypes = ["ipsw", "raw", "img"].compactMap { UTType(filenameExtension: $0) }
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            newMachine(app, url.pathExtension.lowercased() == "ipsw" ? "macos" : "linux", file: url.path)
        }
    }

    /// Makes one with the next free name ("debian", "debian2"…); it shows in the sidebar at once, and how far it got.
    /// macOS asks first, unless it's from a file of the user's: it downloads over 20 GB.
    static func newMachine(_ app: AppModel, _ image: String, file: String? = nil) {
        Task {
            if image == "macos", file == nil {
                let detail = String(
                    localized: """
                        Kelp downloads macOS from Apple (over 20 GB), installs and sets it up: about 20 minutes. \
                        It takes 6 GB of memory while it runs, none while it sleeps.
                        """)
                guard
                    await confirm(
                        String(localized: "Make a macOS machine?"), detail: detail, action: String(localized: "Make It")
                    )
                else { return }
            }
            let base =
                ["debian-13": "debian", "linux": "linux", "macos": "macos", "android": "android", "ios": "iphone"][
                    image] ?? "vm"
            var name = base, n = 2
            while machineList(app).contains(where: { $0.id == name }) {
                name = "\(base)\(n)"
                n += 1
            }
            if await app.call(VMCreate(name: name, image: image, file: file)) != nil { app.watchAgain(.machines) }   // as the daemon has it
        }
    }

    /// The machine's tab, on the screen in front.
    static func openMachine(_ app: AppModel, _ name: String) {
        app.workbench.open(TabURI.machine(name), workspace: app.workbench.workspaceId ?? app.worktrees.first?.id)
    }

    /// A terminal in the machine (nil `command`: its shell), in this screen's project folder, shared at the same path; in
    /// its home folder when that folder can't be shared or is a remote project's.
    static func runInMachine(_ app: AppModel, _ name: String, command: String? = nil) {
        let folder = app.workbench.workspaceId.flatMap(app.worktree)?.path
        // A remote project's folder is on its host, not here to share: the machine's home, run from this Mac (`kelp`
        // isn't on the host).
        let remote = folder.map { RemoteHost.of($0) != nil } ?? false
        let home = remote || (folder.map { !VMs.mayShare($0) } ?? true)
        var line = "kelp vm run " + ShellQuote.word(name) + (home ? " --home" : "")
        if let command { line += " -- " + command }
        app.workbench.starterForNewTab?.run(command: line, title: name, cwd: remote ? NSHomeDirectory() : nil)
    }

    /// Run Terminals In ▸ This Mac or a machine: from then on the project's new terminals and Run commands start in that
    /// machine, in the same folder (the daemon's `SessionSetup.inMachine`); its agents stay here and reach it with
    /// `kelp vm run`. This Mac's projects only, and only machines that share folders (Linux, macOS).
    static func addRunIn(to menu: NSMenu, _ repo: Repo, _ app: AppModel) {
        let machines = machineList(app).filter { $0.machine.kind.sharesFolders && $0.notMade != true }
        guard RemoteHost.of(repo.path) == nil, !machines.isEmpty else { return }
        var all: [String: JSONValue] = [:]
        if case .object(let saved)? = app.uiState[Repo.machineKey] { all = saved }
        let now = all[repo.id]?.string
        let sub = NSMenu()
        func pick(_ name: String?) {
            all[repo.id] = name.map(JSONValue.string)
            Task { await app.uiState.save(Repo.machineKey, .object(all)) }
        }
        sub.add(String(localized: "This Mac")) { pick(nil) }.state = now == nil ? .on : .off
        sub.addItem(.separator())
        for info in machines {
            let name = info.machine.name
            sub.add(name) { pick(name) }.state = now == name ? .on : .off
        }
        menu.add(String(localized: "Run Terminals In"), submenu: sub)
        menu.addItem(.separator())
    }

    /// The machines as the daemon last told (`WatchTopic.machines`).
    static func machineList(_ app: AppModel) -> [VMInfo] { app.latest(MachinesEvent.self)?.machines ?? [] }

    /// Start, sleep or stop it; its row follows as the daemon pushes the list again.
    static func control(_ app: AppModel, machine name: String, _ action: VMControl.Action) {
        Task {
            if await app.call(VMControl(name: name, action: action)) != nil { app.watchAgain(.machines) }   // as the daemon has it now
        }
    }

    /// One whose making failed, made again as it was (`vm.create` with its name alone).
    static func makeAgain(_ app: AppModel, _ name: String) {
        Task {
            if await app.call(VMCreate(name: name)) != nil { app.watchAgain(.machines) }   // as the daemon has it now
        }
    }

    /// Asks first, then stops it and erases its folder (disk, keys, password): there's no getting it back. One still being
    /// made stops being made (Stop Making), what it downloaded dropped.
    static func deleteMachine(_ app: AppModel, _ info: VMInfo) {
        let name = info.machine.name
        Task {
            let size = info.diskMiB.map { bytes($0 << 20) }
            let detail =
                size.map {
                    String(localized: "Its disk and everything on it (\($0)) are erased. This can't be undone.")
                }
                ?? String(localized: "Its disk and everything on it are erased. This can't be undone.")
            let asked =
                info.state == .creating
                ? await confirm(
                    String(localized: "Stop making “\(name)”?"),
                    detail: String(localized: "What it downloaded and made so far is deleted."),
                    action: String(localized: "Stop Making"), destructive: true)
                : await confirm(
                    String(localized: "Delete “\(name)”?"), detail: detail, action: String(localized: "Delete"),
                    destructive: true)
            guard asked else { return }
            guard await app.call(VMControl(name: name, action: .delete)) != nil else { return }
            app.workbench.closeTab(uri: TabURI.machine(name))
            app.watchAgain(.machines)   // as the daemon has it now
        }
    }

    /// What a machine's state reads as, and in what colour.
    static func machineWord(_ v: VMInfo) -> (text: String, color: NSColor) {
        switch v.state {
        case .running: (String(localized: "Running"), .textGreen)
        case .starting: (String(localized: "Starting…"), .secondaryLabelColor)
        case .paused: (String(localized: "Paused"), .secondaryLabelColor)
        case .sleeping: (String(localized: "Asleep"), .secondaryLabelColor)
        case .off: (String(localized: "Off"), .secondaryLabelColor)
        case .creating: (String(localized: "Being made"), .secondaryLabelColor)
        case .error:
            v.notMade == true ? (String(localized: "Failed"), .textRed) : (String(localized: "Didn't start"), .textRed)
        }
    }

    /// Where making it got: the step in the user's words, and how far ("Downloading macOS 27.2 · 43%").
    static func stepText(_ v: VMInfo) -> String {
        let what = v.detail ?? ""
        let text: String =
            switch v.step {
            case .asking: String(localized: "Asking Apple for the latest macOS")
            case .downloading: String(localized: "Downloading \(what)")
            case .checking: String(localized: "Checking \(what)")
            case .unpacking: String(localized: "Unpacking \(what)")
            case .disk: String(localized: "Making its disk")
            case .installing: String(localized: "Installing \(what)")
            case .firstBoot: String(localized: "Setting macOS up (a few minutes)")
            case .lettingIn: String(localized: "Letting Kelp in")
            case .device: String(localized: "Making its device from \(what)")
            case .building: String(localized: "Building Kelp's runner")
            case .starting, nil: String(localized: "Starting for the first time")
            }
        return text + (v.progress.map { " · " + $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
    }

    /// The machine's second line: what it takes of the Mac (CPU and memory while it runs, else its disk) and what runs.
    /// `short`, the row's: a sleeping one's disk alone, how fast it wakes left to the tooltip (it didn't fit the row).
    static func machineLine(_ app: AppModel, _ info: VMInfo, short: Bool = false) -> String {
        switch info.state {
        case .creating: return stepText(info)
        case .error: return info.detail ?? ""
        case .sleeping, .off:
            let wake =
                info.state == .off
                ? String(localized: "Boots in a few seconds")
                : info.machine.kind == .linux
                    ? String(localized: "Wakes in under a second") : String(localized: "Wakes in a few seconds")
            guard let disk = info.diskMiB else { return wake }
            let size = String(localized: "\(bytes(disk << 20)) on disk")
            return short ? size : size + " · " + wake
        default:
            var parts: [String] = []
            if let cpu = info.cpu { parts.append(String(localized: "\(String(format: "%.0f%%", cpu)) CPU")) }
            if let memory = info.memoryMiB { parts.append(bytes(memory << 20)) }
            let connections = info.connections ?? 0
            if connections > 0 {
                parts.append(String(localized: "\(connections) running"))
            }
            // Nothing runs, but an agent drives its screen (`VMInfo.sessions` names it then).
            else if let sessionId = info.sessions?.first {
                parts.append(
                    String(localized: "\(app.catalog.name(app.session(sessionId)?.agent)) is using the screen"))
            } else {
                parts.append(String(localized: "Nothing running"))
            }
            return parts.joined(separator: " · ")
        }
    }
}

extension VMImage {
    /// The image's mark in the sidebar: its distribution's letter on its colour.
    var mark: (letter: String, color: NSColor) {
        switch id {
        case let imageId where imageId.hasPrefix("debian"): ("D", NSColor(hex: 0xA80030))
        case let imageId where imageId.hasPrefix("ubuntu"): ("U", NSColor(hex: 0xE95420))
        case let imageId where imageId.hasPrefix("fedora"): ("F", NSColor(hex: 0x51A2DA))
        case "macos": ("", NSColor(hex: 0x5A6B8C))
        case "android": ("", NSColor(hex: 0x2E9E5B))
        case "ios": ("", NSColor(hex: 0x3478F6))
        default: (String(title.prefix(1)), .systemGray)
        }
    }
}

extension TabURI {
    static func machine(_ name: String) -> String { "vm:" + name }
}
