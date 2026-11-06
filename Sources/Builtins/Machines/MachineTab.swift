import AppKit
import SwiftUI
import Core
import DesignKit
import KelpKit
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
        let v = NSHostingView(rootView: MachineView(app: app, name: name).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        v.sizingOptions = []   // a tab fills the space it's given; it must never resize the window to its ideal size
        view = v
    }
    func focus() {}
}

struct MachineView: View {
    let app: AppModel, name: String
    private var info: VMInfo? { app.machines.first { $0.machine.name == name } }
    private var detail: VMDetail? { app.machineDetail[name] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.gapWide) {
            Text(name).font(.ui(13, weight: .semibold))
            if let v = info {
                let word = app.machineWord(v)
                Text(word.text).font(.ui(11)).foregroundStyle(Color(nsColor: word.color))
                Text(summary(v)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let os = info?.machine.os, os != "linux" {
                Button(String(localized: "Show Screen")) { app.control(machine: name, .show) }
                    .disabled(info.map { [.creating, .error].contains($0.state) } ?? true)
            }
            Button(String(localized: "Terminal")) { app.runInMachine(name) }
                .disabled(info.map { [.creating, .error].contains($0.state) } ?? true)
            Menu {
                if let v = info {
                    switch v.state {
                    case .running, .paused, .starting:
                        Button(String(localized: "Sleep")) { app.control(machine: name, .sleep) }
                        Button(String(localized: "Shut Down")) { app.control(machine: name, .stop) }
                    case .sleeping, .off: Button(String(localized: "Start")) { app.control(machine: name, .start) }
                    case .creating, .error: EmptyView()
                    }
                }
                Divider()
                Button(String(localized: "Copy Run Command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("kelp vm run \(name) -- ", forType: .string)
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(String(localized: "More"))
        }
        .controlSize(.small)
        .padding(.leading, Metrics.inset).padding(.trailing, Metrics.gap)
        .frame(height: Metrics.contentBar)
    }

    /// "Debian 13 · 2 CPUs · 1.2 of 2 GB · disk 3.1 GB".
    private func summary(_ v: VMInfo) -> String {
        let m = v.machine
        var parts = [VMImage.named(m.image)?.title ?? m.image, String(localized: "\(m.cpus) CPUs")]
        let total = Double(m.memoryMiB) / 1024
        if let now = v.memoryMiB { parts.append(String(format: String(localized: "%.1f of %.0f GB"), Double(now) / 1024, total)) }
        else { parts.append(String(format: "%.0f GB", total)) }
        if let d = v.diskMiB { parts.append(String(format: String(localized: "disk %.1f GB"), Double(d) / 1024)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let v = info {
            switch v.state {
            case .running, .paused, .starting: running(v).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .creating:
                VStack(spacing: Metrics.gapWide) {
                    LoadingLine(app.stepText(v))
                    if let p = v.progress { ProgressView(value: p).frame(width: 240) }
                }
                .offset(y: -Metrics.emptyLift).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error:
                ContentUnavailableView {
                    Label(String(localized: "\(name) wasn't made"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(v.detail ?? "").font(.ui(11).monospaced()).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .sleeping, .off:
                ScrollView {   // what it is stays in view: its files, and its size to change while it's shut down
                    VStack(spacing: 0) {
                        asleep(v).frame(maxWidth: .infinity).padding(.vertical, 24)
                        machine(v)
                    }
                }
            }
        } else {
            ContentUnavailableView(String(localized: "No machine called \(name)"), systemImage: "shippingbox",
                                   description: Text("`kelp vm list` shows the machines."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func asleep(_ v: VMInfo) -> some View {
        ContentUnavailableView {
            Label(v.state == .sleeping ? String(localized: "\(name) is asleep") : String(localized: "\(name) is shut down"),
                  systemImage: v.state == .sleeping ? "moon" : "power")
        } description: {
            Text(v.state == .sleeping
                 ? String(localized: "It holds none of this Mac's memory. The next command wakes it in under a second, with all it ran.")
                 : String(localized: "The next command boots it in a few seconds."))
        } actions: {
            Button(v.state == .sleeping ? String(localized: "Wake") : String(localized: "Start")) { app.control(machine: name, .start) }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Open Terminal")) { app.runInMachine(name) }
        }
    }

    private func running(_ v: VMInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let g = detail?.guest { screen(g) }
                heading("Running")
                if let runs = detail?.runs, !runs.isEmpty {
                    ForEach(runs, id: \.pid) { runRow($0) }
                } else {
                    quiet(v.state == .paused ? "Paused: nothing has run for a while. The next command goes on at once."
                          : "Nothing runs in it now. Agents use it with kelp vm run.")
                }
                if let d = detail, !d.ports.isEmpty, let address = d.address {
                    heading("Listening").padding(.top, 10)
                    ForEach(d.ports.filter { $0 != 22 }, id: \.self) { portRow($0, address) }
                }
                if let folders = detail?.folders, !folders.isEmpty {
                    heading("Shared Folders").padding(.top, 10)
                    ForEach(folders, id: \.self) { f in
                        Text((f as NSString).abbreviatingWithTildeInPath).font(.ui(12)).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                }
                machine(v)
            }
            .padding(.horizontal, Metrics.inset).padding(.bottom, Metrics.inset)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// A macOS machine's screen: whose turn it is (agents read and drive it from the Mac's side, nothing to allow), and
    /// the password for a dialog inside that asks for it.
    @ViewBuilder private func screen(_ g: VMDetail.Guest) -> some View {
        heading("Screen")
        VStack(alignment: .leading, spacing: 6) {
            let holder = g.screen.flatMap(app.session).map { app.catalog.displayName($0) } ?? g.screen
            Text(holder.map { String(localized: "In use by \($0)") } ?? String(localized: "Free: agents take turns on it"))
                .font(.ui(12)).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Show Screen")) { app.control(machine: name, .show) }
                Button(String(localized: "Type Password")) { Task { _ = await app.call(VMType(name: name)) } }
                    .help(String(localized: "Types this machine's password into the field that asks for it, in its window."))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 6).padding(.bottom, 10)
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text).sectionTitle().frame(height: Metrics.rowSection, alignment: .bottom)
    }
    private func quiet(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.ui(12)).foregroundStyle(.secondary).padding(.horizontal, 6)
    }

    /// A `kelp vm run`: the chat it came from (a terminal's shows as Terminal), its command, how long it has run.
    private func runRow(_ r: VMDetail.Run) -> some View {
        let s = r.session.flatMap(app.session)
        return Button { if let s { app.workbench.focus(session: s.id) } } label: {
            HStack(spacing: Metrics.gap) {
                if let s, s.isChat, let icon = app.catalog.icon(s.agent, size: 14) {
                    Image(nsImage: icon).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "terminal").font(.symbol(Metrics.iconSmall)).foregroundStyle(.secondary).frame(width: 14)
                }
                Text(s.map { app.catalog.displayName($0) } ?? String(localized: "Terminal")).font(.ui(12)).lineLimit(1)
                Text(r.command.isEmpty ? String(localized: "shell") : r.command).font(.ui(11).monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Self.elapsed(r.seconds)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
        .disabled(s == nil)
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
    private func machine(_ v: VMInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let files = v.files { exchange(files) }
            heading("Machine").padding(.top, 10)
            facts(v)
            if ["linux", "macos"].contains(v.machine.os), v.state != .off {
                quiet("Shut it down to change its processors, memory or disk.")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// Its exchange folder: `~/Kelp` inside, a folder beside the machine here.
    private func exchange(_ files: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Files").padding(.top, 10)
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
            guard let new = await app.call(VMConfigure(name: name, cpus: cpus, memory: memory, disk: disk)),
                  let i = app.machines.firstIndex(where: { $0.id == new.id }) else { return }
            app.machines[i] = new
        }
    }

    /// What it is, a row each; processors, memory and a Linux disk as steppers while it's shut down (a disk only grows).
    private func facts(_ v: VMInfo) -> some View {
        let m = v.machine, cores = ProcessInfo.processInfo.activeProcessorCount
        let gib = max(1, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2), least = m.os == "macos" ? 4 : 1
        let editable = ["linux", "macos"].contains(m.os) && v.state == .off
        let phone = m.os == "android"
        func row(_ label: String, _ value: some View) -> some View {
            GridRow {
                Text(label).font(.ui(12)).foregroundStyle(.secondary)
                value.font(.ui(12))
            }
        }
        func text(_ s: String) -> some View { Text(s).textSelection(.enabled) }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(String(localized: "Image"), text(VMImage.named(m.image)?.title ?? m.image))
            if editable {
                row(String(localized: "Processors"), Stepper("\(m.cpus)", value: Binding(get: { m.cpus }, set: { resize(cpus: $0) }), in: 1...cores))
                row(String(localized: "Memory"), Stepper("\(m.memoryMiB >> 10) GB", value: Binding(get: { m.memoryMiB >> 10 }, set: { resize(memory: $0) }),
                                                         in: least...max(least, gib)))
            } else {
                row(String(localized: "Processors"), text("\(m.cpus)"))
                row(String(localized: "Memory"), text(memory(v)))
            }
            if !phone {
                if editable && m.os == "linux" {
                    row(String(localized: "Disk"), Stepper(String(format: String(localized: "%.1f GB of %d GB"), Double(v.diskMiB ?? 0) / 1024, m.diskGiB),
                                                           value: Binding(get: { m.diskGiB }, set: { resize(disk: $0) }), in: m.diskGiB...2048, step: 8))
                } else {
                    row(String(localized: "Disk"), text(String(format: String(localized: "%.1f GB of %d GB"), Double(v.diskMiB ?? 0) / 1024, m.diskGiB)))
                }
                row(String(localized: "Account"), text(m.user))
                row(String(localized: "Intel programs"), text(m.rosetta ? String(localized: "Through Rosetta") : String(localized: "Off")))
                row(String(localized: "Address"), text(detail?.address ?? "—"))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
    }

    private func memory(_ v: VMInfo) -> String {
        let total = Double(v.machine.memoryMiB) / 1024
        guard let now = v.memoryMiB else { return String(format: "%.0f GB", total) }
        return String(format: String(localized: "%.1f GB of %.0f GB in use by it"), Double(now) / 1024, total)
    }

    /// 41 → "0:41", 4321 → "1:12:01".
    static func elapsed(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
