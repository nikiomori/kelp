import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "vm:<name>" — a machine at a glance: what runs in it (each `kelp vm run`, with the chat it came from), the ports
/// something listens on (open in Kelp's browser), the folders shared with it and what it is. Watched while the tab is open
/// (`WatchTopic.machineDetail`), with the list (the sidebar may be hidden); reading never wakes it.
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        ContentBar {
            Text(name).font(.ui(TextSize.body, weight: .semibold))
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
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(String(localized: "More"))
        }
    }

    /// Nothing to run in: it's being made, or making it failed (a machine whose start failed boots again on a command).
    private var unusable: Bool { info.map { $0.state == .creating || $0.notMade == true } ?? true }

    /// "Debian 13 · 2 CPUs (12%) · 1.2 GB in use · 3.1 GB on disk", sizes as its sidebar row says them.
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
                ScrollView {   // what it is stays in view: its files, and its size to change while it's shut down
                    VStack(spacing: 0) {
                        asleep(info).frame(maxWidth: .infinity).padding(.vertical, 24)
                        machine(info)
                    }
                }
            }
        } else {
            EmptyState(String(localized: "No machine called \(name)"), symbol: "shippingbox") {
                Text("`kelp vm list` shows the machines.")
            }
        }
    }

    /// Making it failed (Try Again, Delete), or its last start did (its disk is whole: Start tries again).
    private func failed(_ info: VMInfo) -> some View {
        let notMade = info.notMade == true
        return EmptyState(
            notMade ? String(localized: "\(name) wasn't made") : String(localized: "\(name) didn't start"),
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
                ? String(localized: "\(name) is asleep") : String(localized: "\(name) is shut down"),
            symbol: info.state == .sleeping ? "moon" : "power", lifted: false
        ) {
            Text(
                info.state == .sleeping
                    ? String(
                        localized:
                            "It holds none of this Mac's memory. The next command wakes it in under a second, with all it ran."
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

    private func running(_ info: VMInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let guest = detail?.guest { screen(guest) }
                Text("Running").sectionHeading()
                if let runs = detail?.runs, !runs.isEmpty {
                    ForEach(runs, id: \.pid) { runRow($0) }
                } else {
                    let note: LocalizedStringKey =
                        info.state == .paused
                        ? "Paused: nothing has run for a while. The next command goes on at once."
                        : "Nothing runs in it now. Agents use it with kelp vm run."
                    Text(note).quietNote().padding(.horizontal, 6)
                }
                if let detail, !detail.ports.isEmpty, let address = detail.address {
                    Text("Listening").sectionHeading().padding(.top, Metrics.gapWide)
                    ForEach(detail.ports.filter { $0 != 22 }, id: \.self) { portRow($0, address) }
                }
                if let folders = detail?.folders, !folders.isEmpty {
                    Text("Shared Folders").sectionHeading().padding(.top, Metrics.gapWide)
                    ForEach(folders, id: \.self) { folder in
                        Text((folder as NSString).abbreviatingWithTildeInPath).font(.ui(TextSize.row)).lineLimit(1)
                            .truncationMode(
                                .middle
                            )
                            .padding(.horizontal, 6).padding(.vertical, Metrics.lineGap)
                    }
                }
                machine(info)
            }
            .padding(.horizontal, Metrics.inset).padding(.bottom, Metrics.inset)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// A macOS machine's screen: whose turn it is (agents read and drive it from the Mac's side, nothing to allow), and
    /// the password for a dialog inside that asks for it.
    @ViewBuilder private func screen(_ guest: VMDetail.Guest) -> some View {
        Text("Screen").sectionHeading()
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
                            localized: "Types this machine's password into the field that asks for it, in its window."))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 6).padding(.bottom, Metrics.gapWide)
    }

    /// A `kelp vm run`: the chat it came from (a terminal's shows as Terminal), its command, how long it has run.
    private func runRow(_ run: VMDetail.Run) -> some View {
        let session = run.session.flatMap(app.session)
        return Button {
            if let session { app.workbench.focus(session: session.id) }
        } label: {
            HStack(spacing: Metrics.gap) {
                if let session, session.isChat, let icon = app.catalog.icon(session.agent, size: 14) {
                    Image(nsImage: icon).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "terminal").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary).frame(
                        width: 14)
                }
                Text(session.map { app.catalog.displayName($0) } ?? String(localized: "Terminal")).font(
                    .ui(TextSize.row)
                )
                .lineLimit(1)
                Text(run.command.isEmpty ? String(localized: "shell") : run.command).font(
                    .ui(TextSize.caption).monospaced()
                )
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Self.elapsed(run.seconds)).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(
                    .secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
        .disabled(session == nil)
    }

    private func portRow(_ port: Int, _ address: String) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(String(port)).font(.ui(TextSize.row).monospacedDigit())
            Text("\(address):\(String(port))").font(.ui(TextSize.caption).monospaced()).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(String(localized: "Open")) { app.workbench.open("http://\(address):\(port)") }.controlSize(.small)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    /// Its files and what it is: the end of the running view, and below the asleep one.
    private func machine(_ info: VMInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let files = info.files { exchange(files) }
            Text("Machine").sectionHeading().padding(.top, Metrics.gapWide)
            facts(info)
            if info.machine.kind.resizable, info.state != .off {
                Text("Shut it down to change its processors, memory or disk.").quietNote().padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// Its exchange folder: `~/Kelp` inside, a folder beside the machine here.
    private func exchange(_ files: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files").sectionHeading().padding(.top, Metrics.gapWide)
            VStack(alignment: .leading, spacing: 6) {
                Text("~/Kelp in it is this folder on your Mac: put files there for it, take what it leaves.")
                    .font(.ui(TextSize.row)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Open in Finder")) {   // the daemon made it with the list
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: files)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 6)
        }
    }

    /// Changes its size: one of processors, memory (GB) or disk (GB) at a time, the list updated with the answer.
    private func resize(cpus: Int? = nil, memory: Int? = nil, disk: Int? = nil) {
        Task {
            // The list as the daemon has it now, pushed again: one source for it, not a copy patched here.
            if await app.call(VMConfigure(name: name, cpus: cpus, memory: memory, disk: disk)) != nil {
                app.watchAgain(.machines)
            }
        }
    }

    /// What it is, a row each; processors, memory and a Linux disk as steppers while it's shut down (a disk only grows).
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
        .padding(.horizontal, 6)
    }

    private func memory(_ info: VMInfo) -> String {
        let given = bytes(info.machine.memoryMiB << 20)
        guard let now = info.memoryMiB else { return given }
        return String(localized: "\(bytes(now << 20)) of the Mac's (\(given) given)")
    }

    /// What a disk of `gib` may grow to: the next few of the usual sizes, up to the 2 TB a machine may have.
    static func growSizes(_ gib: Int) -> [Int] { Array([64, 128, 256, 512, 1024, 2048].filter { $0 > gib }.prefix(4)) }

    /// A disk only grows: asked first, as there's no making it smaller again.
    private func grow(to gib: Int) {
        Task {
            guard
                await confirm(
                    String(localized: "Grow \(name)'s disk to \(bytes(gib << 30))?"),
                    detail: String(
                        localized:
                            "A disk can't be made smaller again. It takes room on this Mac only as it fills."),
                    action: String(localized: "Grow"))
            else { return }
            resize(disk: gib)
        }
    }

    /// 41 → "0:41", 4321 → "1:12:01".
    static func elapsed(_ s: Int) -> String {
        Duration.seconds(s).formatted(.time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
