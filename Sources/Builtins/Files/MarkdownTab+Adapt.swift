import AppKit
import Core
import DesignKit
import KelpKit

/// Also in Other Formats… (the studio's format menu): a sheet of formats and a length, and the page's agent makes each
/// as a motion page of its own, laid out again for that shape rather than cropped, and exports them all (OpenMotion's
/// Platform export, Jitter's Resize and batch export). Kelp only collects the request.
extension MarkdownTab {
    func askAdaptations() {
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Also in Other Formats")
            alert.informativeText = String(
                localized: "Its agent makes each as a page of its own, laid out again for the shape, and exports them.")
            let (w, h) = MotionPage.size(editor.text)
            let choices = MotionStudio.formats.filter { ($0.width, $0.height) != (w, h) }
            let boxes = choices.map { f in
                NSButton(checkboxWithTitle: "\(f.name) · \(f.width) × \(f.height)", target: nil, action: nil)
            }
            boxes.prefix(2).forEach { $0.state = .on }
            let length = PointerPopUpButton()
            length.addItems(withTitles: [
                String(localized: "As it is"), String(localized: "15 seconds"), String(localized: "6 seconds")
            ])
            let column = NSStackView(views: boxes + [length])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Metrics.gap
            column.frame.size = NSSize(width: Metrics.alertAccessory, height: column.fittingSize.height)
            alert.accessoryView = column
            let who = pageAuthor.map { app.catalog.name($0.agent) } ?? String(localized: "the Agent")
            alert.addButton(withTitle: String(localized: "Ask \(who)"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            let picked = zip(choices, boxes).filter { $0.1.state == .on }.map(\.0)
            guard !picked.isEmpty else { return }
            let lasts = [nil, "15 s", "6 s"][max(0, length.indexOfSelectedItem)]
            send(
                Self.adaptations(
                    page: Artifacts.projectPath(url.path), formats: picked.map { ($0.name, $0.width, $0.height) },
                    length: lasts))
        }
    }

    /// The request for the page in each of `formats`.
    static func adaptations(page: String, formats: [(name: String, width: Int, height: Int)], length: String?) -> String
    {
        let list = formats.map { "\($0.name) (\($0.width) × \($0.height))" }.joined(separator: ", ")
        return "Adapt \(page) for \(list): make each a motion page of its own (kelp artifact new motion \"… · 9:16\"), "
            + "the same scenes and words laid out again for the shape, not cropped"
            + (length.map { ", \($0) long" } ?? ", as long as it is")
            + ". Then export each: kelp artifact export <name> mp4."
    }
}
