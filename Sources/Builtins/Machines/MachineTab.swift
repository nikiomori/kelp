import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "vm:<name>": a machine at a glance. It shows what runs in it (each `kelp vm run`, with the chat it came from), the
/// ports something listens on (they open in Kelp's browser), the folders shared with it, and what it is. It is watched
/// while the tab is open (`WatchTopic.machineDetail`), along with the list, because the sidebar may be hidden.
/// Reading it never wakes the machine.
@MainActor
func machineTab(uri: String, app: AppModel) -> KelpKit.TabContent {   // not SwiftUI's
    let name = TabURI.body(uri)
    return HostedTabContent(
        uri: uri, title: name, icon: "shippingbox", app: app, watching: [(.machines, ""), (.machineDetail, name)],
        MachineView(app: app, name: name))
}

struct MachineView: View {
    let app: AppModel, name: String
    private var info: VMInfo? { Machines.machineList(app).first { $0.machine.name == name } }
    private var detail: VMDetail? { app.latest(MachineEvent.self, name)?.detail }
    /// The list hasn't come for over a second, so the tab says it reads it (`whileSlow`'s rule).

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        ContentBar {
            Text(name).font(.ui(TextSize.body, weight: .semibold)).layoutPriority(1)
            if let info {
                let word = Machines.machineWord(info)
                Text(word.text).font(.ui(TextSize.caption)).foregroundStyle(Color(nsColor: word.color))
                Text(summary(info)).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(
                    1
                )
                .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if info?.machine.kind.hasScreen == true {
                Button(String(localized: "Show Screen")) { Machines.control(app, machine: name, .show) }
                    .disabled(unusable)
            }
            Button(String(localized: "Terminal")) { Machines.runInMachine(app, name) }.disabled(unusable)
            Menu {
                if let info { MachineControls(app: app, info: info) }
                Divider()
                Button(String(localized: "Copy Run Command")) {
                    copyText("kelp vm run \(name) -- ")
                }
                if let log = info?.log {
                    Button(String(localized: "Show Log")) { app.workbench.open(TabURI.file(log)) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.symbol())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerMenu()
            .help(String(localized: "More Actions")).accessibilityLabel(String(localized: "More Actions"))
        }
    }

    /// Whether there's nothing to run in, because the machine is being made or making it failed. A machine whose start
    /// failed boots again on a command.
    private var unusable: Bool { !(info.map { Machines.usable($0) } ?? false) }

    /// "Debian 13 · 2 CPUs (12%) · 1.2 GB in use · 3.1 GB on disk", with sizes as its sidebar row says them.
    private func summary(_ info: VMInfo) -> String {
        let machine = info.machine
        var parts = [VMImage.named(machine.image)?.title ?? machine.image, String(localized: "\(machine.cpus) CPUs")]
        if let cpu = info.cpu { parts[1] += String(format: " (%.0f%%)", cpu) }
        if let now = info.memoryMiB {
            parts.append(String(localized: "\(bytes(now << 20)) in use"))
        } else {
            parts.append(bytes(machine.memoryMiB << 20))
        }
        if let disk = info.diskMiB {
            parts.append(String(localized: "\(bytes(disk << 20)) on disk"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let info {
            switch info.state {
            case .running, .paused, .starting:
                running(info).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .creating:
                VStack(spacing: Metrics.gapWide) {
                    LoadingLine(Machines.stepText(info))
                    if let progress = info.progress { ProgressView(value: progress).frame(width: 240) }
                    Button(String(localized: "Stop Making…")) { Machines.deleteMachine(app, info) }
                }
                .offset(y: -Metrics.emptyLift).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error: failed(info)
            case .sleeping, .off:
                // What the machine is stays in view: its files, and its size to change while it's shut down.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        asleep(info).frame(maxWidth: .infinity).padding(.vertical, 24)
                        // At the running view's edge, so the facts don't move when the machine sleeps.
                        machine(info).padding(.horizontal, Metrics.pageInset - Metrics.inset)
                            .padding(.bottom, Metrics.pageTop)
                    }
                }
            }
        } else if app.latest(MachinesEvent.self) == nil {   // not "no such machine" before the list has come
            LoadingPage(String(localized: "Reading the machines…"))
        } else {
            EmptyState(String(localized: "No Machine Called \(name)"), symbol: "shippingbox") {
                Text("`kelp vm list` shows the machines.")
            }
        }
    }

    /// Shown when making the machine failed (Try Again, Delete), or its last start did (its disk is whole, so Start
    /// tries again).
    private func failed(_ info: VMInfo) -> some View {
        let notMade = info.notMade == true
        return EmptyState(
            notMade ? String(localized: "\(name) Wasn’t Made") : String(localized: "\(name) Didn’t Start"),
            symbol: "exclamationmark.triangle"
        ) {
            Text(info.detail ?? "").font(.ui(TextSize.caption).monospaced()).textSelection(.enabled)
        } actions: {
            if notMade {
                Button(String(localized: "Try Again")) { Machines.makeAgain(app, name) }.keyboardShortcut(
                    .defaultAction)
                Button(String(localized: "Delete…")) { Machines.deleteMachine(app, info) }
            } else {
                Button(String(localized: "Start")) { Machines.control(app, machine: name, .start) }
                    .keyboardShortcut(.defaultAction)
            }
            if let log = info.log {
                Button(String(localized: "Show Log")) { app.workbench.open(TabURI.file(log)) }
            }
        }
    }

    private func asleep(_ info: VMInfo) -> some View {
        EmptyState(
            info.state == .sleeping
                ? String(localized: "\(name) Is Asleep") : String(localized: "\(name) Is Shut Down"),
            symbol: info.state == .sleeping ? "moon" : "power", lifted: false
        ) {
            Text(
                info.state == .sleeping
                    ? String(
                        localized:
                            "It holds none of this Mac’s memory. The next command wakes it in under a second, with all it ran."
                    )
                    : String(localized: "The next command boots it in a few seconds."))
        } actions: {
            Button(info.state == .sleeping ? String(localized: "Wake") : String(localized: "Start")) {
                Machines.control(app, machine: name, .start)
            }
            .keyboardShortcut(.defaultAction)
            Button(String(localized: "Open Terminal")) { Machines.runInMachine(app, name) }
        }
    }

    /// The running machine's column: its screen, then what runs in it, what listens and what it shares as lists that
    /// fold (`SectionList`, the server page's too), then its files and what it is. Everything starts at one edge:
    /// the lists' rows are a panel's inset in from the column's.
    private func running(_ info: VMInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let guest = detail?.guest { screen(guest) }
                SectionList(lists(info), scrolls: false)
                machine(info)
            }
            .padding(.horizontal, Metrics.pageInset - Metrics.inset).padding(.bottom, Metrics.pageTop)
            .frame(maxWidth: Metrics.pageColumn, alignment: .leading)
        }
    }

    private func lists(_ info: VMInfo) -> [SectionList.Section] {
        let app = app
        let note =
            info.state == .paused
            ? String(localized: "Paused: nothing has run for a while. The next command goes on at once.")
            : String(localized: "Nothing runs in it now. Agents use it with kelp vm run.")
        var all = [
            SectionList.Section(
                id: "runs", title: String(localized: "Running"), rows: (detail?.runs ?? []).map(runRow), note: note)
        ]
        if let detail, let address = detail.address {
            let ports = detail.ports.filter { $0 != 22 }.map { port -> SectionList.Row in
                var row = SectionList.Row(id: "port \(port)", title: "")
                row.key = "\(port)"
                row.trailing = "\(address):\(port)"
                row.button = .init(String(localized: "Open")) { app.workbench.open("http://\(address):\(port)") }
                row.open = row.button?.run
                return row
            }
            if !ports.isEmpty { all.append(.init(id: "ports", title: String(localized: "Listening"), rows: ports)) }
        }
        if let folders = detail?.folders, !folders.isEmpty {
            let rows = folders.map { folder -> SectionList.Row in
                var row = SectionList.Row(id: folder, title: (folder as NSString).abbreviatingWithTildeInPath)
                row.path = true
                return row
            }
            all.append(.init(id: "folders", title: String(localized: "Shared Folders"), rows: rows))
        }
        return all
    }

    /// A macOS machine's screen: whose turn it is (agents read and drive it from the Mac's side, so there is nothing
    /// to allow), and the password for a dialog inside that asks for it.
    @ViewBuilder private func screen(_ guest: VMDetail.Guest) -> some View {
        Text("Screen").sectionHeading().padding(.horizontal, Metrics.inset)
        VStack(alignment: .leading, spacing: 6) {
            let holder = guest.screen.flatMap(app.session).map { app.catalog.displayName($0) } ?? guest.screen
            Text(
                holder.map { String(localized: "In use by \($0)") }
                    ?? String(localized: "Free: agents take turns on it")
            )
            .font(.ui(TextSize.row)).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Show Screen")) { Machines.control(app, machine: name, .show) }
                Button(String(localized: "Type Password")) { Task { _ = await app.call(VMType(name: name)) } }
                    .help(
                        String(
                            localized: "Types this machine’s password into the field that asks for it, in its window."))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Metrics.inset).padding(.bottom, Metrics.gapWide)
    }

    /// A `kelp vm run`: the chat it came from (a terminal's shows as Terminal), its command, and how long it has run.
    private func runRow(_ run: VMDetail.Run) -> SectionList.Row {
        let app = app, session = run.session.flatMap(app.session)
        var row = SectionList.Row(
            id: "run \(run.pid)", title: session.map { app.catalog.displayName($0) } ?? String(localized: "Terminal"))
        if let session, session.isChat, let icon = app.catalog.icon(session.agent, size: Metrics.appIcon) {
            row.icon = { NSImageView(image: icon) }
            row.iconKey = session.agent
        } else {
            row.icon = SectionList.symbol("terminal")
        }
        row.detail = run.command.isEmpty ? String(localized: "shell") : run.command
        row.mono = true
        row.trailing = Self.elapsed(run.seconds)
        if let session { row.click = { app.workbench.focus(session: session.id) } }
        return row
    }

    /// The machine's files and what it is, at the end of the running view and below the asleep one.
    private func machine(_ info: VMInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let files = info.files { exchange(files) }
            Text("Machine").sectionHeading().padding(.top, Metrics.gapWide).padding(.horizontal, Metrics.inset)
            facts(info)
            if info.machine.kind.resizable, info.state != .off {
                Text("Shut it down to change its processors, memory or disk.").quietNote()
                    .padding(.horizontal, Metrics.inset)
            }
        }
        .frame(maxWidth: Metrics.pageColumn, alignment: .leading)
    }

    /// The machine's exchange folder: `~/Kelp` inside it, and a folder beside the machine here.
    private func exchange(_ files: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files").sectionHeading().padding(.top, Metrics.gapWide).padding(.horizontal, Metrics.inset)
            VStack(alignment: .leading, spacing: 6) {
                Text("~/Kelp in it is this folder on your Mac: put files there for it, take what it leaves.")
                    .font(.ui(TextSize.row)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Open in Finder")) {   // the daemon made the folder along with the list
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: files)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, Metrics.inset)
        }
    }

    /// Changes the machine's size: one of processors, memory (GB) or disk (GB) at a time, with the list updated from
    /// the answer.
    private func resize(cpus: Int? = nil, memory: Int? = nil, disk: Int? = nil) {
        Task { await Machines.change(app, VMConfigure(name: name, cpus: cpus, memory: memory, disk: disk)) }
    }

    /// What the machine is, a row each. Processors, memory and a Linux disk show as steppers while it's shut down (a
    /// disk only grows).
    private func facts(_ info: VMInfo) -> some View {
        let machine = info.machine, cores = ProcessInfo.processInfo.activeProcessorCount
        let editable = machine.kind.resizable && info.state == .off
        let phone = machine.kind == .android
        func row(_ label: String, _ value: some View) -> some View {
            GridRow {
                Text(label).font(.ui(TextSize.row)).foregroundStyle(.secondary)
                value.font(.ui(TextSize.row))
            }
        }
        func text(_ s: String) -> some View { Text(s).textSelection(.enabled) }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(String(localized: "Image"), text(VMImage.named(machine.image)?.title ?? machine.image))
            if editable {
                row(
                    String(localized: "Processors"),
                    Stepper(
                        "\(machine.cpus)", value: Binding(get: { machine.cpus }, set: { resize(cpus: $0) }),
                        in: 1...cores))
                row(
                    String(localized: "Memory"),
                    Stepper(
                        bytes(machine.memoryMiB << 20),
                        value: Binding(get: { machine.memoryMiB >> 10 }, set: { resize(memory: $0) }),
                        in: machine.kind.memoryRange()))
            } else {
                row(String(localized: "Processors"), text("\(machine.cpus)"))
                row(String(localized: "Memory"), text(memory(info)))
            }
            if !phone {
                let disk = String(localized: "\(bytes((info.diskMiB ?? 0) << 20)) of \(bytes(machine.diskGiB << 30))")
                if editable && machine.kind == .linux {
                    row(
                        String(localized: "Disk"),
                        HStack(spacing: Metrics.gap) {
                            text(disk)
                            Menu(String(localized: "Grow")) {
                                ForEach(Self.growSizes(machine.diskGiB), id: \.self) { gib in
                                    Button(bytes(gib << 30)) { grow(to: gib) }
                                }
                            }
                            .fixedSize()
                        })
                } else {
                    row(String(localized: "Disk"), text(disk))
                }
                row(String(localized: "Account"), text(machine.user))
                row(
                    String(localized: "Intel programs"),
                    text(machine.rosetta ? String(localized: "Through Rosetta") : String(localized: "Off")))
                row(String(localized: "Address"), text(detail?.address ?? "—"))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Metrics.inset)
    }

    private func memory(_ info: VMInfo) -> String {
        let given = bytes(info.machine.memoryMiB << 20)
        guard let now = info.memoryMiB else { return given }
        return String(localized: "\(bytes(now << 20)) of the Mac’s (\(given) given)")
    }

    /// What a disk of `gib` may grow to: the next few of the usual sizes, up to the 2 TB a machine may have.
    static func growSizes(_ gib: Int) -> [Int] { Array([64, 128, 256, 512, 1024, 2048].filter { $0 > gib }.prefix(4)) }

    /// Grows the disk after asking first, because there's no making it smaller again.
    private func grow(to gib: Int) {
        Task {
            guard
                await confirm(
                    String(localized: "Grow \(name)’s disk to \(bytes(gib << 30))?"),
                    detail: String(
                        localized:
                            "A disk can’t be made smaller again. It takes room on this Mac only as it fills."),
                    action: String(localized: "Grow"))
            else { return }
            resize(disk: gib)
        }
    }

    /// 41 → "0:41", 4321 → "1:12:01".
    nonisolated static func elapsed(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
