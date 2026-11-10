import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// "vm:<name>" — a machine at a glance: what runs in it (each `kelp vm run`, with the chat it came from), the ports
/// something listens on (open in Kelp's browser), the folders shared with it and what it is. Watched while the tab is open
/// (`WatchTopic.machineDetail`); reading never wakes it.
@MainActor
final class MachineTab: KelpKit.TabContent {   // not SwiftUI's
    let uri: String
    let view: NSView
    private let name: String
    /// The list (the sidebar may be hidden) and what runs in this one, for as long as the tab is open.
    private let list: Watched, detail: Watched
    var title: String { name }
    var icon: NSImage? { .symbol("shippingbox") }
    init(uri: String, app: AppModel) {
        self.uri = uri
        name = TabURI.body(uri)
        list = Watched(.machines, in: app)
        list.key = ""
        detail = Watched(.machineDetail, in: app)
        detail.key = name
        view = HostedTab(MachineView(app: app, name: name))
    }
    func focus() {}
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
            Text(name).font(.ui(13, weight: .semibold))
            if let info {
                let word = Machines.machineWord(info)
                Text(word.text).font(.ui(11)).foregroundStyle(Color(nsColor: word.color))
                Text(summary(info)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if info?.machine.kind.hasScreen == true {
                Button(String(localized: "Show Screen")) { Machines.control(app, machine: name, .show) }
                    .disabled(info.map { [.creating, .error].contains($0.state) } ?? true)
            }
            Button(String(localized: "Terminal")) { Machines.runInMachine(app, name) }
                .disabled(info.map { [.creating, .error].contains($0.state) } ?? true)
            Menu {
                if let info { MachineControls(app: app, info: info) }
                Divider()
                Button(String(localized: "Copy Run Command")) {
                    copyText("kelp vm run \(name) -- ")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(String(localized: "More"))
        }
    }

    /// "Debian 13 · 2 CPUs (12%) · 1.2 GB in use · disk 3.1 GB".
    private func summary(_ info: VMInfo) -> String {
        let machine = info.machine
        var parts = [VMImage.named(machine.image)?.title ?? machine.image, String(localized: "\(machine.cpus) CPUs")]
        if let cpu = info.cpu { parts[1] += String(format: " (%.0f%%)", cpu) }
        if let now = info.memoryMiB {
            parts.append(String(format: String(localized: "%.1f GB in use"), Double(now) / 1024))
        } else {
            parts.append(bytes(machine.memoryMiB << 20))
        }
        if let disk = info.diskMiB {
            parts.append(String(format: String(localized: "disk %.1f GB"), Double(disk) / 1024))
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
                }
                .offset(y: -Metrics.emptyLift).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error:
                ContentUnavailableView {
                    Label(String(localized: "\(name) wasn't made"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(info.detail ?? "").font(.ui(11).monospaced()).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .sleeping, .off:
                ScrollView {   // what it is stays in view: its files, and its size to change while it's shut down
                    VStack(spacing: 0) {
                        asleep(info).frame(maxWidth: .infinity).padding(.vertical, 24)
                        machine(info)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                String(localized: "No machine called \(name)"), systemImage: "shippingbox",
                description: Text("`kelp vm list` shows the machines.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func asleep(_ info: VMInfo) -> some View {
        ContentUnavailableView {
            Label(
                info.state == .sleeping
                    ? String(localized: "\(name) is asleep") : String(localized: "\(name) is shut down"),
                systemImage: info.state == .sleeping ? "moon" : "power")
        } description: {
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
                    Text("Listening").sectionHeading().padding(.top, 10)
                    ForEach(detail.ports.filter { $0 != 22 }, id: \.self) { portRow($0, address) }
                }
                if let folders = detail?.folders, !folders.isEmpty {
                    Text("Shared Folders").sectionHeading().padding(.top, 10)
                    ForEach(folders, id: \.self) { folder in
                        Text((folder as NSString).abbreviatingWithTildeInPath).font(.ui(12)).lineLimit(1)
                            .truncationMode(
                                .middle
                            )
                            .padding(.horizontal, 6).padding(.vertical, 3)
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
            .font(.ui(12)).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Show Screen")) { Machines.control(app, machine: name, .show) }
                Button(String(localized: "Type Password")) { Task { _ = await app.call(VMType(name: name)) } }
                    .help(
                        String(
                            localized: "Types this machine's password into the field that asks for it, in its window."))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 6).padding(.bottom, 10)
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
                Text(session.map { app.catalog.displayName($0) } ?? String(localized: "Terminal")).font(.ui(12))
                    .lineLimit(1)
                Text(run.command.isEmpty ? String(localized: "shell") : run.command).font(.ui(11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Self.elapsed(run.seconds)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
        .disabled(session == nil)
    }

    private func portRow(_ port: Int, _ address: String) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(String(port)).font(.ui(12).monospacedDigit())
            Text("\(address):\(String(port))").font(.ui(11).monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Button(String(localized: "Open")) { app.workbench.open("http://\(address):\(port)") }.controlSize(.small)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    /// Its files and what it is: the end of the running view, and below the asleep one.
    private func machine(_ info: VMInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let files = info.files { exchange(files) }
            Text("Machine").sectionHeading().padding(.top, 10)
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
            Text("Files").sectionHeading().padding(.top, 10)
            VStack(alignment: .leading, spacing: 6) {
                Text("~/Kelp in it is this folder on your Mac: put files there for it, take what it leaves.")
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text(label).font(.ui(12)).foregroundStyle(.secondary)
                value.font(.ui(12))
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
                        "\(machine.memoryMiB >> 10) GB",
                        value: Binding(get: { machine.memoryMiB >> 10 }, set: { resize(memory: $0) }),
                        in: machine.kind.memoryRange()))
            } else {
                row(String(localized: "Processors"), text("\(machine.cpus)"))
                row(String(localized: "Memory"), text(memory(info)))
            }
            if !phone {
                if editable && machine.kind == .linux {
                    row(
                        String(localized: "Disk"),
                        Stepper(
                            String(
                                format: String(localized: "%.1f GB of %d GB"), Double(info.diskMiB ?? 0) / 1024,
                                machine.diskGiB),
                            value: Binding(get: { machine.diskGiB }, set: { resize(disk: $0) }),
                            in: machine.diskGiB...2048, step: 8
                        ))
                } else {
                    row(
                        String(localized: "Disk"),
                        text(
                            String(
                                format: String(localized: "%.1f GB of %d GB"), Double(info.diskMiB ?? 0) / 1024,
                                machine.diskGiB)
                        ))
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
        let total = Double(info.machine.memoryMiB) / 1024
        guard let now = info.memoryMiB else { return bytes(info.machine.memoryMiB << 20) }
        return String(format: String(localized: "%.1f GB of the Mac's (%.0f GB given)"), Double(now) / 1024, total)
    }

    /// 41 → "0:41", 4321 → "1:12:01".
    static func elapsed(_ s: Int) -> String {
        Duration.seconds(s).formatted(.time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
