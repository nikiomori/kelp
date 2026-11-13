import AppKit
import Core
import DesignKit
import KelpKit

/// What the Message field shows of the agent writing the commit: its logo and chevron in the field's corner, the line
/// that replaces the text while it reads, the words under the field after, and the plan over the button.
@MainActor
final class AgentCommitControls {
    let logo: IconButton
    let chevron: IconButton
    let corner: NSStackView
    let mark = StatusMark(size: 12)
    let working = NSTextField(labelWithString: "")
    let work: NSStackView
    let noteLogo = NSImageView()
    let noteText = NSTextField(labelWithString: "")
    let again: PointerButton
    /// Its tab, while it waits for an answer there.
    let watch: PointerButton
    let note: NSStackView
    let plan = CommitPlanView()
    /// The plan the cards were made from: a message typed into one updates it without making the cards again.
    var shown: CommitPlan?

    init(_ c: SourceControlController) {
        logo = IconButton(nil, tip: "", target: c, action: #selector(SourceControlController.askLastAgent))
        chevron = IconButton(
            .symbol("chevron.down"), tip: String(localized: "Choose an Agent"), target: c,
            action: #selector(SourceControlController.agentMenu))
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        corner = NSStackView(views: [logo, chevron])
        corner.spacing = 0
        working.font = .ui(TextSize.body)
        working.textColor = .secondaryLabelColor
        working.lineBreakMode = .byTruncatingTail
        working.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        watch = Self.link(String(localized: "Show"), c, #selector(SourceControlController.showAgentSession))
        let stop = IconButton(
            .symbol("stop.circle"), tip: String(localized: "Stop"), target: c,
            action: #selector(SourceControlController.stopAgentCommit))
        work = NSStackView(views: [mark, working, NSView(), watch, stop])
        work.spacing = Metrics.gap
        noteLogo.imageScaling = .scaleProportionallyDown
        noteLogo.widthAnchor.constraint(equalToConstant: 12).isActive = true
        noteLogo.heightAnchor.constraint(equalToConstant: 12).isActive = true
        noteText.font = .ui(TextSize.caption)
        noteText.textColor = .secondaryLabelColor
        noteText.lineBreakMode = .byTruncatingTail
        noteText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        again = Self.link(String(localized: "Ask Again"), c, #selector(SourceControlController.askAgainForCommits))
        note = NSStackView(views: [noteLogo, noteText, again])
        note.spacing = Metrics.gap
        plan.onEdit = { [weak c] i, text in
            guard let c, let wid = c.worktreeId, c.plans[wid]?.commits.indices.contains(i) == true else { return }
            c.plans[wid]?.commits[i].message = text
            c.agentUI.shown = c.plans[wid]
        }
        plan.onRemove = { [weak c] i in c?.editPlan { $0.commits.remove(at: i) } }
        plan.onAskAgain = { [weak c] in c?.askAgainForCommits() }
        plan.onDiscard = { [weak c] in c?.discardPlan() }
        plan.onCommit = { [weak c] in c?.makeCommits(push: false) }
    }

    /// A word that acts, in the link colour, underlined under the pointer.
    private static func link(_ title: String, _ target: AnyObject, _ action: Selector) -> PointerButton {
        let b = PointerButton(title: title) {}
        b.target = target
        b.action = action
        b.contentTintColor = .linkColor
        b.font = .ui(TextSize.caption)
        b.underlinesOnHover = true
        return b
    }
}

extension SourceControlController {
    /// The field, the words and the plan as `worktreeId`'s agent and plan stand.
    func showAgentCommit() {
        let ui = agentUI, wid = worktreeId ?? ""
        let run = agentCommits[wid], plan = plans[wid], note = notes[wid]
        let icon = app.catalog.icon(run?.agentId ?? note?.agentId ?? lastAgent?.id, size: 14)
        ui.logo.image = app.catalog.icon(lastAgent?.id, size: 14)
        ui.logo.toolTip = lastAgent.map { String(localized: "Write the commit with \($0.name) (⌥⌘↩)") }
        messageField?.isHidden = plan != nil
        messageScroll?.isHidden = run != nil
        placeholder.isHidden = run != nil || !message.string.isEmpty
        ui.corner.isHidden = run != nil || commitAgentsEmpty
        message.corner = ui.corner.isHidden ? 0 : ui.corner.fittingSize.width + Metrics.gap
        ui.work.isHidden = run == nil
        if let run {
            ui.mark.status = run.status == .waiting ? .waiting : .working
            ui.watch.isHidden = run.status != .waiting
            ui.working.stringValue =
                run.status == .waiting
                ? String(localized: "\(run.agent) needs your answer")
                : String(localized: "\(run.agent) is reading \(run.files) files…")
        }
        ui.note.isHidden = note == nil || run != nil || plan != nil
        if let note {
            ui.noteLogo.image = icon
            ui.noteText.stringValue = note.text
        }
        ui.plan.isHidden = plan == nil
        if plan != ui.shown {
            ui.shown = plan
            if let plan { ui.plan.show(plan, logo: icon) }
            rebuildChanges()   // the rows' commit numbers
        }
        updateCommitButton()
    }

    private var commitAgentsEmpty: Bool { lastAgent == nil }
}
