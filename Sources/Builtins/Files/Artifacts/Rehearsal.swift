import AppKit
import Core
import DesignKit
import KelpKit

/// A rehearsal of a deck (Keynote's Rehearse, PowerPoint's Rehearse Timings): Present with Notes against a length
/// aimed at, the speaker's window keeping the time on each slide; at the end, how long each took, and Send to Agent
/// with what ran long.
enum Rehearsal {
    /// 192 seconds as `3:12`.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// The slides that ran long: over 1.5 times their share of the length aimed at, the longest first.
    static func long(_ times: [Double], target: Double) -> [Int] {
        let share = target / Double(max(times.count, 1))
        return times.indices.filter { times[$0] > share * 1.5 }.sorted { times[$0] > times[$1] }
    }

    /// What the agent is told: the length aimed at and taken, each slide's time, what to cut.
    static func message(page: String, times: [Double], target: Double) -> String {
        let total = times.reduce(0, +), share = target / Double(max(times.count, 1))
        var lines = [
            "Rehearsed \(page): aimed at \(clock(target)), took \(clock(total)).",
            "Per slide: " + times.enumerated().map { "\($0.offset + 1) \(clock($0.element))" }.joined(separator: ", ")
                + "."
        ]
        let long = long(times, target: target)
        if total > target, !long.isEmpty {
            lines.append(
                "Longest: " + long.map { "\($0 + 1) (\(clock(times[$0])))" }.joined(separator: ", ")
                    + "; cut each toward \(clock(share)), keeping what it says.")
        }
        return lines.joined(separator: "\n")
    }
}

extension MarkdownTab {
    /// Rehearse…: asks the length aimed at, then presents with notes, timing each slide.
    func rehearse() {
        Task {
            let minutes = await prompt(
                String(localized: "Rehearse"),
                String(localized: "How many minutes to aim at? Each slide is timed while you present with notes."),
                initial: "10", action: String(localized: "Rehearse"))
            guard let minutes else { return }
            Presenter.start(for: self, rehearsing: max(1, Double(minutes) ?? 10) * 60)
        }
    }

    /// The rehearsal's times, slide by slide, and Send to Agent.
    func rehearsed(_ times: [Double], target: Double) {
        guard times.contains(where: { $0 > 0 }) else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Rehearsal: \(Rehearsal.clock(times.reduce(0, +))) of \(Rehearsal.clock(target))")
            let long = Set(Rehearsal.long(times, target: target))
            alert.informativeText = times.enumerated().map {
                String(localized: "Slide \($0.offset + 1)") + "  " + Rehearsal.clock($0.element)
                    + (long.contains($0.offset) ? "  ·  " + String(localized: "ran long") : "")
            }.joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "Send to Agent"))
            alert.addButton(withTitle: String(localized: "Done"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            send(Rehearsal.message(page: Artifacts.projectPath(url.path), times: times, target: target))
        }
    }
}
