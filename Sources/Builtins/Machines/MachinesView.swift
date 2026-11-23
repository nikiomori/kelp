import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The sidebar's Machines block, above the plan limits. Its heading has a + (for a new machine: Linux, macOS, Android,
/// iOS, or from a file), and is there while the Machines extension is on and the block isn't hidden (Settings ›
/// Machines), with no machine too, so the + makes the first. Under it is each machine with its state in a word and a
/// colour, its memory and what runs in it, and the agents with a command there. A click opens its tab; a right-click
/// starts, sleeps or stops it. The chevron folds the block to its heading, where each machine stays as its mark, in
/// colour while it runs.
struct MachinesView: View {
    let app: AppModel
    /// The list, watched while it's shown. The daemon reads the machines every 5 s, and every second while one starts.
    @State private var watched: Watched?
    /// What + offers, read once rather than at every redraw, because it looks for an Android SDK and Xcode on disk.
    @State private var choices: [(title: String, image: String, missing: String?)] = []
    /// Whether the block is folded to its heading: a view preference of this Mac.
    @AppStorage("machines.folded") private var folded = false

    /// Made only while Machines is on (`Contributions.sidebarSections`). When it's off, nothing of it is drawn or
    /// watched.
    var body: some View { block }

    private var block: some View {
        // The loader hangs off a container that always exists while the block is on, because on an EmptyView `.task`
        // never runs.
        let machines = Machines.machineList(app)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if app.settings[SettingKeys.machinesInSidebar] {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    heading(machines)
                    if !folded { ForEach(machines) { row($0) }.transition(.opacity) }
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

    /// The chevron and title, which fold the block; folded, each machine's mark after them; the + at the end. With no
    /// machine there is nothing to fold: the title stands alone.
    private func heading(_ machines: [VMInfo]) -> some View {
        HStack(spacing: Metrics.gap) {
            if machines.isEmpty {
                Text("Machines").sectionTitle()
            } else {
                Button(action: fold) {
                    HStack(spacing: Metrics.gapTight) {
                        Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                        Text("Machines").sectionTitle()
                    }
                }
                .buttonStyle(PointerButtonStyle(flush: true))
                .accessibilityLabel(
                    folded ? String(localized: "Expand Machines") : String(localized: "Collapse Machines"))
            }
            if folded {
                HStack(spacing: Metrics.gapTight) { ForEach(machines) { chip($0) } }.transition(.opacity)
            }
            Spacer(minLength: Metrics.gap)
            add
        }
        // As `SectionHeading` stands it: the line 4 pt over the row's bottom, the + centred on the title.
        .padding(.bottom, 4)
        .frame(height: TextSize.of(Metrics.rowSection), alignment: .bottom).padding(.leading, Metrics.gap)
        .contextMenu { headingMenu(folds: !machines.isEmpty) }
    }

    /// The heading's right-click: fold, hide the block (Settings › Machines brings it back) or open its settings.
    @ViewBuilder private func headingMenu(folds: Bool) -> some View {
        if folds {
            Button(folded ? String(localized: "Expand") : String(localized: "Collapse"), action: fold)
            Divider()
        }
        Button(String(localized: "Hide Machines")) {
            app.settings.set(SettingKeys.machinesInSidebar, false)
            Banner.show(String(localized: "Machines are hidden. Settings › Machines brings them back."))
        }
        Button(String(localized: "Machines Settings…")) {
            app.extensions.run("workbench.openSettings", ["section": .string("machines")])
        }
    }

    /// Folds or unfolds the block: the chevron turns and the rows come and go as a fold does.
    private func fold() {
        withAnimation(Motion.reduced ? nil : .timingCurve(0.25, 0.8, 0.25, 1, duration: Motion.fold)) {
            folded.toggle()
        }
    }

    /// A machine in the folded heading: its mark, glowing in its colour while it runs. A click opens its tab, and a
    /// right-click is its row's menu.
    private func chip(_ vmInfo: VMInfo) -> some View {
        let word = Machines.machineWord(vmInfo).text
        return Button {
            Machines.openMachine(app, vmInfo.machine.name)
        } label: {
            mark(vmInfo, size: Metrics.appIcon, symbol: Metrics.iconTiny)
        }
        .buttonStyle(PointerButtonStyle(flush: true))
        .contextMenu { menu(vmInfo) }
        .help("\(vmInfo.machine.name) — \(word)")
        .accessibilityLabel("\(vmInfo.machine.name), \(word), \(Machines.machineLine(app, vmInfo))")
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
                .help(String(localized: "macOS from a restore image (.ipsw), Linux from a cloud image’s raw disk"))
        } label: {
            Image(systemName: "plus").font(.symbol(Metrics.iconSmall))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerMenu()
        .help(String(localized: "New Machine"))
        .accessibilityLabel(String(localized: "New Machine"))
    }

    private func row(_ vmInfo: VMInfo) -> some View {
        let word = Machines.machineWord(vmInfo)
        return Button {
            Machines.openMachine(app, vmInfo.machine.name)
        } label: {
            line(vmInfo, word: word.text, wordColor: word.color)
        }
        .buttonStyle(PointerButtonStyle())   // the grey fill under the pointer, and the dip when pressed
        .contextMenu { menu(vmInfo) }
        .help(vmInfo.state == .error ? (vmInfo.detail ?? "") : Machines.machineLine(app, vmInfo))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vmInfo.machine.name), \(word.text), \(Machines.machineLine(app, vmInfo))")
    }

    /// A machine's mark: its kind's symbol (a Linux image's letter) on its colour, grey while it sleeps or is off. The
    /// small one in the folded heading glows in its colour while the machine runs.
    private func mark(_ vmInfo: VMInfo, size: CGFloat, symbol: CGFloat) -> some View {
        let mark = VMImage.named(vmInfo.machine.image)?.mark ?? ("?", .systemGray)
        let asleep = [.sleeping, .off, .error].contains(vmInfo.state), small = size < Metrics.iconButton
        return Group {
            switch vmInfo.machine.kind {
            case .macos: Image(systemName: "apple.logo").font(.symbol(symbol))
            case .android: Image(systemName: "smartphone").font(.symbol(symbol))
            case .ios: Image(systemName: "iphone").font(.symbol(symbol))
            case .linux: Text(mark.letter).font(.ui(small ? TextSize.micro : TextSize.caption, weight: .semibold))
            }
        }
        .foregroundStyle(.white).frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: small ? Metrics.radiusXS : Metrics.radiusSM).fill(Color(nsColor: mark.color))
        )
        .saturation(asleep ? 0 : 1).opacity(asleep ? 0.6 : 1)
        .shadow(color: small && !asleep ? Color(nsColor: mark.color) : .clear, radius: Metrics.iconGlow / 2)
    }

    /// The row's mark, its name and state, and its line under them.
    private func line(_ vmInfo: VMInfo, word: String, wordColor: NSColor) -> some View {
        HStack(spacing: Metrics.gapWide) {
            mark(vmInfo, size: Metrics.iconButton, symbol: Metrics.iconSmall)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                HStack(spacing: Metrics.gap) {
                    Text(vmInfo.machine.name).font(.ui(TextSize.body)).lineLimit(1)   // as every name in the sidebar
                    if vmInfo.state == .starting || vmInfo.state == .creating {
                        StatusIcon(status: .working)   // the ring of an agent at work, still with Reduce Motion
                    }
                    Text(word).font(.ui(TextSize.caption)).foregroundStyle(Color(nsColor: wordColor)).lineLimit(1)
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
        // The style pads by gapTight itself, so the mark stays a gap in from the fill's edge.
        .padding(.horizontal, Metrics.gap - Metrics.gapTight).frame(height: TextSize.of(Metrics.rowTwoLine))
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
