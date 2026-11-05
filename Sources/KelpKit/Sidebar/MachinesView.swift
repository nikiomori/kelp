import AppKit
import SwiftUI
import Core
import DesignKit

/// The sidebar's Machines block, over the plan limits: each machine with its state in a word and colour, its memory and
/// what runs in it, and the agents with a command there. A click opens its tab; a right-click starts, sleeps or stops it.
/// Nothing shows until there's a machine.
struct MachinesView: View {
    let app: AppModel
    @State private var hovered: String?

    var body: some View {
        // The loader hangs off a container that always exists: on an EmptyView `.task` never runs.
        VStack(alignment: .leading, spacing: 0) {
            if !app.machines.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Machines").sectionTitle().frame(height: Metrics.rowSection, alignment: .bottom).padding(.leading, Metrics.gap)
                    ForEach(app.machines) { row($0) }
                }
                .padding(.horizontal, Metrics.gapWide).padding(.bottom, Metrics.gap)
            }
        }
        .fontDesign(app.themes.chromeDesign)
        // Watched while shown: the daemon reads them every 5 s, every second while one starts.
        .onAppear { app.watch(.machines) }
        .onDisappear { app.unwatch(.machines) }
    }

    private func row(_ v: VMInfo) -> some View {
        let word = app.machineWord(v)
        let mark = VMImage.named(v.machine.image)?.mark ?? ("?", .systemGray)
        let asleep = [.sleeping, .off, .error].contains(v.state)
        return HStack(spacing: Metrics.gapWide) {
            Group {
                if v.machine.os == "macos" { Image(systemName: "apple.logo").font(.ui(12, weight: .semibold)) }
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
