import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The sidebar's Machines block, above the plan limits. Its heading has a + (for a new machine: Linux, macOS, Android,
/// iOS, or from a file), and is there while the Machines extension is on and there is a machine. Under it is each
/// machine with its state in a word and a colour, its memory and what runs in it, and the agents with a command there.
/// A click opens its tab; a right-click starts, sleeps or stops it.
struct MachinesView: View {
    let app: AppModel
    /// The list, watched while it's shown. The daemon reads the machines every 5 s, and every second while one starts.
    @State private var watched: Watched?
    @State private var hovered: String?
    /// What + offers, read once rather than at every redraw, because it looks for an Android SDK and Xcode on disk.
    @State private var choices: [(title: String, image: String, missing: String?)] = []

    /// Made only while Machines is on (`Contributions.sidebarSections`). When it's off, nothing of it is drawn or
    /// watched.
    var body: some View { block }

    private var block: some View {
        // The loader hangs off a container that always exists while the block is on, because on an EmptyView `.task`
        // never runs. With no machine the block draws nothing (File › New Machine… makes the first), because the
        // block is for those who have one.
        let machines = Machines.machineList(app)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !machines.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Metrics.gap) {
                        Text("Machines").sectionTitle()
                        Spacer(minLength: Metrics.gap)
                        add
                    }
                    .frame(height: TextSize.of(Metrics.rowSection)).padding(.leading, Metrics.gap)
                    ForEach(machines) { row($0) }
                }
                .padding(.horizontal, Metrics.gapWide).padding(.bottom, Metrics.gapWide)
            }
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

    /// The + menu: a new machine of each kind this Mac can run. A kind the Mac lacks something for is greyed out and
    /// says why.
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

    private func row(_ vmInfo: VMInfo) -> some View {
        let word = Machines.machineWord(vmInfo)
        let mark = VMImage.named(vmInfo.machine.image)?.mark ?? ("?", .systemGray)
        let asleep = [.sleeping, .off, .error].contains(vmInfo.state)
        return HStack(spacing: Metrics.gapWide) {
            Group {
                switch vmInfo.machine.kind {
                case .macos: Image(systemName: "apple.logo").font(.ui(TextSize.row, weight: .semibold))
                case .android: Image(systemName: "smartphone").font(.ui(TextSize.row, weight: .semibold))
                case .ios: Image(systemName: "iphone").font(.ui(TextSize.row, weight: .semibold))
                case .linux: Text(mark.letter).font(.ui(TextSize.caption, weight: .semibold))
                }
            }
            .foregroundStyle(.white).frame(
                width: Metrics.iconButton, height: Metrics.iconButton
            )
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(Color(nsColor: mark.color)))
            .saturation(asleep ? 0 : 1).opacity(asleep ? 0.6 : 1)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                HStack(spacing: Metrics.gap) {
                    Text(vmInfo.machine.name).font(.ui(TextSize.body)).lineLimit(1)   // as every name in the sidebar
                    if vmInfo.state == .starting || vmInfo.state == .creating { ProgressView().controlSize(.mini) }
                    Text(word.text).font(.ui(TextSize.caption)).foregroundStyle(Color(nsColor: word.color)).lineLimit(1)
                    Spacer(minLength: Metrics.gap)
                    faces(vmInfo)
                }
                Text(Machines.machineLine(app, vmInfo, short: true)).font(.ui(TextSize.caption).monospacedDigit())
                    .foregroundStyle(
                        .secondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Metrics.gap).frame(height: TextSize.of(Metrics.rowTwoLine))
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(
                hovered == vmInfo.id ? Color(nsColor: .fillHover) : .clear)
        )
        .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? vmInfo.id : (hovered == vmInfo.id ? nil : hovered) }
        .onTapGesture { Machines.openMachine(app, vmInfo.machine.name) }
        .contextMenu { menu(vmInfo) }
        .help(vmInfo.state == .error ? (vmInfo.detail ?? "") : Machines.machineLine(app, vmInfo))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vmInfo.machine.name), \(word.text), \(Machines.machineLine(app, vmInfo))")
        .accessibilityAddTraits(.isButton)
    }

    /// The agents with a command running in the machine: their icons, overlapping.
    @ViewBuilder private func faces(_ vmInfo: VMInfo) -> some View {
        let agents = (vmInfo.sessions ?? []).compactMap { app.session($0)?.agent }
        HStack(spacing: -Metrics.appIcon / 3) {   // overlapping, as a stack of faces
            ForEach(Array(Set(agents)).sorted().prefix(3), id: \.self) { agent in
                if let icon = app.catalog.icon(agent, size: Metrics.iconLarge) {
                    Image(nsImage: icon).frame(width: Metrics.iconLarge, height: Metrics.iconLarge)
                }
            }
        }
    }

    @ViewBuilder private func menu(_ vmInfo: VMInfo) -> some View {
        let name = vmInfo.machine.name
        Button(String(localized: "Open")) { Machines.openMachine(app, name) }
        Button(String(localized: "Open in Own Window")) { Machines.openMachine(app, name, ownWindow: true) }
        Button(String(localized: "Open Terminal")) { Machines.runInMachine(app, name) }.disabled(
            vmInfo.state == .creating || vmInfo.notMade == true)
        Divider()
        MachineControls(app: app, info: vmInfo)
        Divider()
        Button(
            vmInfo.state == .creating ? String(localized: "Stop Making…") : String(localized: "Delete…"),
            role: .destructive
        ) { Machines.deleteMachine(app, vmInfo) }
    }
}

/// Start, Sleep and Shut Down as the machine's state allows, and Try Again for one whose making failed. The row's
/// menu and the tab show the same controls.
struct MachineControls: View {
    let app: AppModel, info: VMInfo

    var body: some View {
        let name = info.machine.name
        switch info.state {
        case .running, .paused:
            Button(String(localized: "Sleep")) { Machines.control(app, machine: name, .sleep) }
            Button(String(localized: "Shut Down")) { Machines.control(app, machine: name, .stop) }
        case .starting:   // a machine starting can't be saved yet, because kelp-vm refuses a sleep until it's up
            Button(String(localized: "Shut Down")) { Machines.control(app, machine: name, .stop) }
        case .sleeping, .off:
            Button(String(localized: "Start")) { Machines.control(app, machine: name, .start) }
            if info.state == .sleeping {   // forgets the saved state, so the next start boots afresh
                Button(String(localized: "Shut Down")) { Machines.control(app, machine: name, .stop) }
            }
        case .error:
            if info.notMade == true {
                Button(String(localized: "Try Again")) { Machines.makeAgain(app, name) }
            } else {   // the machine was made but its last start failed; its disk is whole, and a start tries again
                Button(String(localized: "Start")) { Machines.control(app, machine: name, .start) }
            }
        case .creating: EmptyView()
        }
    }
}
