import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Kelp's virtual machines (Core/VMs.swift) as the sidebar's Machines block and a machine's tab ("vm:<name>") see them.
extension AppModel {
    /// The machine's tab, on the screen in front.
    func openMachine(_ name: String) {
        workbench.open(TabURI.machine(name), workspace: workbench.workspaceId ?? worktrees.first?.id)
    }

    /// A terminal in the machine (nil `command`: its shell), in this screen's project folder, shared at the same path; in
    /// its home folder when that folder can't be shared.
    package func runInMachine(_ name: String, command: String? = nil) {
        let folder = workbench.workspaceId.flatMap(worktree)?.path
        let home = folder.map { !VMs.mayShare($0) } ?? true
        var line = "kelp vm run " + VMs.shellQuoted(name) + (home ? " --home" : "")
        if let command { line += " -- " + command }
        workbench.editor?.run(command: line, title: name)
    }

    /// Start, sleep or stop it; its row shows the answer at once, the watch the rest.
    package func control(machine name: String, _ action: VMControl.Action) {
        Task {
            guard let v = await call(VMControl(name: name, action: action)), let i = machines.firstIndex(where: { $0.id == v.id }) else { return }
            machines[i] = v
        }
    }

    /// The machine the session runs a command in now, if any (`kelp vm run`).
    func machine(runningFor session: String) -> String? { machines.first { $0.sessions?.contains(session) == true }?.machine.name }

    /// What a machine's state reads as, and in what colour; a macOS one whose Kelp Guest lacks a permission wants you.
    package func machineWord(_ v: VMInfo) -> (text: String, color: NSColor) {
        if v.state == .running, let g = machineDetail[v.id]?.guest, !(g.screenRecording && g.accessibility) {
            return (String(localized: "Needs permissions"), .textPurple)
        }
        return switch v.state {
        case .running: (String(localized: "Running"), .textGreen)
        case .starting: (String(localized: "Starting…"), .secondaryLabelColor)
        case .paused: (String(localized: "Paused"), .secondaryLabelColor)
        case .sleeping: (String(localized: "Asleep"), .secondaryLabelColor)
        case .off: (String(localized: "Off"), .secondaryLabelColor)
        case .creating: (String(localized: "Being made"), .secondaryLabelColor)
        case .error: (String(localized: "Failed"), .textRed)
        }
    }

    /// The machine's second line: its memory and what runs, or why there's nothing to say.
    func machineLine(_ v: VMInfo) -> String {
        switch v.state {
        case .creating, .error: return v.detail ?? ""
        case .sleeping: return v.machine.os == "macos" ? String(localized: "Wakes in a few seconds") : String(localized: "Wakes in under a second")
        case .off: return String(localized: "Boots in a few seconds")
        default:
            var parts: [String] = []
            if let m = v.memoryMiB { parts.append(String(format: "%.1f GB", Double(m) / 1024)) }
            let n = v.connections ?? 0
            parts.append(n == 0 ? String(localized: "Nothing running") : String(localized: "\(n) running"))
            return parts.joined(separator: " · ")
        }
    }
}

extension VMImage {
    /// The image's mark in the sidebar: its distribution's letter on its colour.
    var mark: (letter: String, color: NSColor) {
        switch id {
        case let i where i.hasPrefix("debian"): ("D", NSColor(hex: 0xA80030))
        case let i where i.hasPrefix("ubuntu"): ("U", NSColor(hex: 0xE95420))
        case let i where i.hasPrefix("fedora"): ("F", NSColor(hex: 0x51A2DA))
        case "macos": ("", NSColor(hex: 0x5A6B8C))
        default: (String(title.prefix(1)), .systemGray)
        }
    }
}

extension TabURI {
    static func machine(_ name: String) -> String { "vm:" + name }
}
