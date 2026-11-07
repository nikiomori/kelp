import AppKit
import SwiftUI
import Core
import DesignKit

/// The sidebar's Machines block, over the plan limits: its heading with + (a new machine: Linux, macOS, Android, iOS, or
/// from a file), there while the Machines extension is on; under it each machine with its state in a word and colour,
/// its memory and what runs in it, and the agents with a command there. A click opens its tab; a right-click starts,
/// sleeps or stops it.
struct MachinesView: View {
    let app: AppModel
    @State private var hovered: String?
    /// What + offers, read once (it looks for an Android SDK and Xcode on disk), not at every redraw.
    @State private var choices: [(title: String, image: String, missing: String?)] = []

    /// Off, nothing of it is drawn or watched (the daemon then asks no machine how it is).
    private var on: Bool { app.extensions.extensions.contains { $0.id == "kelp.machines" && $0.enabled } }

    var body: some View {
        if on { block }
    }

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
                ForEach(app.machines) { row($0) }
            }
            // Room under it even without machines: the plan limits' rule right under the heading read as its first row.
            .padding(.horizontal, Metrics.gapWide).padding(.bottom, Metrics.gapWide)
        }
        .fontDesign(app.themes.chromeDesign)
        // Watched while shown: the daemon reads them every 5 s, every second while one starts.
        .onAppear { app.watch(.machines); choices = app.machineChoices }
        .onDisappear { app.unwatch(.machines) }
    }

    /// + : a new machine of each kind this Mac can run; what it lacks greys one out and says why.
    private var add: some View {
        Menu {
            ForEach(choices, id: \.image) { c in
                Button(c.title) { app.newMachine(c.image) }.disabled(c.missing != nil).help(c.missing ?? "")
            }
            Divider()
            Button(String(localized: "From a File…")) { app.machineFromFile() }
                .help(String(localized: "macOS from a restore image (.ipsw), Linux from a cloud image's raw disk"))
        } label: {
            Image(systemName: "plus").font(.symbol(Metrics.iconSmall))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "New Machine"))
        .accessibilityLabel(String(localized: "New Machine"))
    }

    private func row(_ v: VMInfo) -> some View {
        let word = app.machineWord(v)
        let mark = VMImage.named(v.machine.image)?.mark ?? ("?", .systemGray)
        let asleep = [.sleeping, .off, .error].contains(v.state)
        return HStack(spacing: Metrics.gapWide) {
            Group {
                if v.machine.os == "macos" { Image(systemName: "apple.logo").font(.ui(12, weight: .semibold)) }
                else if v.machine.os == "android" { Image(systemName: "smartphone").font(.ui(12, weight: .semibold)) }
                else if v.machine.os == "ios" { Image(systemName: "iphone").font(.ui(12, weight: .semibold)) }
                else { Text(mark.letter).font(.ui(11, weight: .bold)) }
            }
                .foregroundStyle(.white).frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(Color(nsColor: mark.color)))
                .saturation(asleep ? 0 : 1).opacity(asleep ? 0.6 : 1)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                HStack(spacing: Metrics.gap) {
                    Text(v.machine.name).font(.ui(12, weight: .semibold)).lineLimit(1)
                    if v.state == .starting || v.state == .creating { ProgressView().controlSize(.mini) }
                    Text(word.text).font(.ui(11)).foregroundStyle(Color(nsColor: word.color)).lineLimit(1)
                    Spacer(minLength: Metrics.gap)
                    faces(v)
                }
                Text(app.machineLine(v)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, Metrics.gap).frame(height: Metrics.rowTwoLine)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(hovered == v.id ? Color(nsColor: .fillHover) : .clear))
        .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? v.id : (hovered == v.id ? nil : hovered) }
        .onTapGesture { app.openMachine(v.machine.name) }
        .contextMenu { menu(v) }
        .help(v.state == .error ? (v.detail ?? "") : app.machineLine(v))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(v.machine.name), \(word.text), \(app.machineLine(v))")
        .accessibilityAddTraits(.isButton)
    }

    /// The agents with a command running in it: their icons, overlapping.
    @ViewBuilder private func faces(_ v: VMInfo) -> some View {
        let agents = (v.sessions ?? []).compactMap { app.session($0)?.agent }
        HStack(spacing: -Metrics.appIcon / 3) {   // overlapping, as a stack of faces
            ForEach(Array(Set(agents)).sorted().prefix(3), id: \.self) { a in
                if let icon = app.catalog.icon(a, size: Metrics.iconLarge) { Image(nsImage: icon).frame(width: Metrics.iconLarge, height: Metrics.iconLarge) }
            }
        }
    }

    @ViewBuilder private func menu(_ v: VMInfo) -> some View {
        let name = v.machine.name
        Button(String(localized: "Open")) { app.openMachine(name) }
        Button(String(localized: "Open Terminal")) { app.runInMachine(name) }.disabled(v.state == .creating || v.state == .error)
        Divider()
        switch v.state {
        case .running, .paused, .starting:
            Button(String(localized: "Sleep")) { app.control(machine: name, .sleep) }
            Button(String(localized: "Shut Down")) { app.control(machine: name, .stop) }
        case .sleeping, .off:
            Button(String(localized: "Start")) { app.control(machine: name, .start) }
            if v.state == .sleeping { Button(String(localized: "Shut Down")) { app.control(machine: name, .stop) } }
        case .creating, .error: EmptyView()
        }
    }
}
