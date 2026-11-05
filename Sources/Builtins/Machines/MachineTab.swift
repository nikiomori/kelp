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
            if info?.machine.os == "macos" {
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
                LoadingLine(v.detail ?? String(localized: "Making it…")).offset(y: -Metrics.emptyLift).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error:
                ContentUnavailableView {
                    Label(String(localized: "\(name) wasn't made"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(v.detail ?? "").font(.ui(11).monospaced()).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .sleeping, .off: asleep(v).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                heading("Machine").padding(.top, 10)
                facts(v)
            }
            .padding(.horizontal, Metrics.inset).padding(.bottom, Metrics.inset)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// A macOS machine's screen: Kelp Guest's permissions until both are on, then whose turn it is.
    @ViewBuilder private func screen(_ g: VMDetail.Guest) -> some View {
        heading("Screen")
        if !g.running || !(g.screenRecording && g.accessibility) {
            VStack(alignment: .leading, spacing: 6) {
                Text(g.running ? "Turn Kelp Guest on in the machine's System Settings › Privacy & Security: Screen Recording and Accessibility."
                     : "Kelp Guest isn't running in it: sign in on its screen.")
                    .font(.ui(12)).foregroundStyle(Color(nsColor: .textPurple)).fixedSize(horizontal: false, vertical: true)
                if g.running {
                    HStack(spacing: 12) {
                        Label(String(localized: "Screen Recording"), systemImage: g.screenRecording ? "checkmark.circle.fill" : "circle")
                        Label(String(localized: "Accessibility"), systemImage: g.accessibility ? "checkmark.circle.fill" : "circle")
                    }
                    .font(.ui(12)).foregroundStyle(.secondary)
                }
                Button(String(localized: "Show Screen")) { app.control(machine: name, .show) }.controlSize(.small)
            }
            .padding(.horizontal, 6).padding(.bottom, 10)
        } else {
            let holder = g.screen.flatMap(app.session).map { app.catalog.displayName($0) } ?? g.screen
            Text(holder.map { String(localized: "In use by \($0)") } ?? String(localized: "Free: agents take turns on it"))
                .font(.ui(12)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 10)
        }
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

    private func facts(_ v: VMInfo) -> some View {
        let m = v.machine
        let rows: [(String, String)] = [
            (String(localized: "Image"), VMImage.named(m.image)?.title ?? m.image),
            (String(localized: "Processors"), "\(m.cpus)"),
            (String(localized: "Memory"), memory(v)),
            (String(localized: "Disk"), String(format: String(localized: "%.1f GB of %d GB"), Double(v.diskMiB ?? 0) / 1024, m.diskGiB)),
            (String(localized: "Account"), m.user),
            (String(localized: "Intel programs"), m.rosetta ? String(localized: "Through Rosetta") : String(localized: "Off")),
            (String(localized: "Address"), detail?.address ?? "—")
        ]
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0).font(.ui(12)).foregroundStyle(.secondary)
                    Text(r.1).font(.ui(12)).textSelection(.enabled)
                }
            }
        }
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
