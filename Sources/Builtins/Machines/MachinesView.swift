import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The sidebar's Machines block, over the plan limits: its heading with + (a new machine: Linux, macOS, Android, iOS, or
/// from a file), there while the Machines extension is on; under it each machine with its state in a word and colour,
/// its memory and what runs in it, and the agents with a command there. A click opens its tab; a right-click starts,
/// sleeps or stops it.
struct MachinesView: View {
    let app: AppModel
    /// The list, watched while it's shown: the daemon reads them every 5 s, every second while one starts.
    @State private var watched: Watched?
    @State private var hovered: String?
    /// What + offers, read once (it looks for an Android SDK and Xcode on disk), not at every redraw.
    @State private var choices: [(title: String, image: String, missing: String?)] = []

    /// Made only while Machines is on (`Contributions.sidebarSections`): off, nothing of it is drawn or watched.
    var body: some View { block }

    private var block: some View {
        // The loader hangs off a container that always exists while it's on: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Metrics.gap) {
                    Text("Machines").sectionTitle()
                    Spacer(minLength: Metrics.gap)
                    add
                }
                .frame(height: Metrics.rowSection).padding(.leading, Metrics.gap)
                ForEach(Machines.machineList(app)) { row($0) }
            }
            // Room under it even without machines: the plan limits' rule right under the heading read as its first row.
            .padding(.horizontal, Metrics.gapWide).padding(.bottom, Metrics.gapWide)
        }
        .fontDesign(app.themes.chromeDesign)
        .onAppear {
            let list = Watched(.machines, in: app)
            list.key = ""
            watched = list
            choices = Machines.machineChoices
        }
        .onDisappear { watched = nil }
    }

    /// + : a new machine of each kind this Mac can run; what it lacks greys one out and says why.
    private var add: some View {
        Menu {
            ForEach(choices, id: \.image) { choice in
                Button(choice.title) { Machines.newMachine(app, choice.image) }.disabled(choice.missing != nil).help(
                    choice.missing ?? "")
            }
            Divider()
            Button(String(localized: "From a File…")) { Machines.machineFromFile(app) }
                .help(String(localized: "macOS from a restore image (.ipsw), Linux from a cloud image's raw disk"))
        } label: {
            Image(systemName: "plus").font(.symbol(Metrics.iconSmall))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerMenu()
        .help(String(localized: "New Machine"))
        .accessibilityLabel(String(localized: "New Machine"))
    }

    private func row(_ v: VMInfo) -> some View {
        let word = Machines.machineWord(v)
        let mark = VMImage.named(v.machine.image)?.mark ?? ("?", .systemGray)
        let asleep = [.sleeping, .off, .error].contains(v.state)
        return HStack(spacing: Metrics.gapWide) {
            Group {
                switch v.machine.kind {
                case .macos: Image(systemName: "apple.logo").font(.ui(TextSize.row, weight: .semibold))
                case .android: Image(systemName: "smartphone").font(.ui(TextSize.row, weight: .semibold))
                case .ios: Image(systemName: "iphone").font(.ui(TextSize.row, weight: .semibold))
                case .linux: Text(mark.letter).font(.ui(TextSize.caption, weight: .semibold))
                }
            }
            .foregroundStyle(.white).frame(width: Metrics.iconButton, height: Metrics.iconButton)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(Color(nsColor: mark.color)))
            .saturation(asleep ? 0 : 1).opacity(asleep ? 0.6 : 1)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                HStack(spacing: Metrics.gap) {
                    Text(v.machine.name).font(.ui(TextSize.row, weight: .semibold)).lineLimit(1)
                    if v.state == .starting || v.state == .creating { ProgressView().controlSize(.mini) }
                    Text(word.text).font(.ui(TextSize.caption)).foregroundStyle(Color(nsColor: word.color)).lineLimit(1)
                    Spacer(minLength: Metrics.gap)
                    faces(v)
                }
                Text(Machines.machineLine(app, v, short: true)).font(.ui(TextSize.caption).monospacedDigit())
                    .foregroundStyle(
                        .secondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Metrics.gap).frame(height: Metrics.rowTwoLine)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(hovered == v.id ? Color(nsColor: .fillHover) : .clear)
        )
        .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? v.id : (hovered == v.id ? nil : hovered) }
        .onTapGesture { Machines.openMachine(app, v.machine.name) }
        .contextMenu { menu(v) }
        .help(v.state == .error ? (v.detail ?? "") : Machines.machineLine(app, v))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(v.machine.name), \(word.text), \(Machines.machineLine(app, v))")
        .accessibilityAddTraits(.isButton)
    }

    /// The agents with a command running in it: their icons, overlapping.
    @ViewBuilder private func faces(_ v: VMInfo) -> some View {
        let agents = (v.sessions ?? []).compactMap { app.session($0)?.agent }
        HStack(spacing: -Metrics.appIcon / 3) {   // overlapping, as a stack of faces
            ForEach(Array(Set(agents)).sorted().prefix(3), id: \.self) { agent in
                if let icon = app.catalog.icon(agent, size: Metrics.iconLarge) {
                    Image(nsImage: icon).frame(width: Metrics.iconLarge, height: Metrics.iconLarge)
                }
            }
        }
    }

    @ViewBuilder private func menu(_ v: VMInfo) -> some View {
        let name = v.machine.name
        Button(String(localized: "Open")) { Machines.openMachine(app, name) }
        Button(String(localized: "Open Terminal")) { Machines.runInMachine(app, name) }.disabled(
            v.state == .creating || v.notMade == true)
        Divider()
        MachineControls(app: app, info: v)
        if v.state != .creating {
            Divider()
            Button(String(localized: "Delete…"), role: .destructive) { Machines.deleteMachine(app, v) }
        }
    }
}

/// Start, Sleep and Shut Down as its state allows, Try Again for one whose making failed: its row's menu and its tab's
/// alike.
struct MachineControls: View {
    let app: AppModel, info: VMInfo

    var body: some View {
        let name = info.machine.name
        switch info.state {
        case .running, .paused:
            Button(String(localized: "Sleep")) { Machines.control(app, machine: name, .sleep) }
            Button(String(localized: "Shut Down")) { Machines.control(app, machine: name, .stop) }
        case .starting:   // one starting can't be saved yet: kelp-vm refuses a sleep until it's up
            Button(String(localized: "Shut Down")) { Machines.control(app, machine: name, .stop) }
        case .sleeping, .off:
            Button(String(localized: "Start")) { Machines.control(app, machine: name, .start) }
            if info.state == .sleeping {   // its saved state forgotten: the next start boots afresh
                Button(String(localized: "Shut Down")) { Machines.control(app, machine: name, .stop) }
            }
        case .error:
            if info.notMade == true {
                Button(String(localized: "Try Again")) { Machines.makeAgain(app, name) }
            } else {   // made, its last start failed: its disk is whole, and a start tries again
                Button(String(localized: "Start")) { Machines.control(app, machine: name, .start) }
            }
        case .creating: EmptyView()
        }
    }
}
