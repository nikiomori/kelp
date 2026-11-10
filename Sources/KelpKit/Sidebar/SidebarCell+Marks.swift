// A sidebar row's marks: the folder's changes, PR and CI badges, and an agent's icon, face, state and chip.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension SidebarCell {
    /// The agent's icon: before its name when Agent icons is Always, a grey glyph after it for an agent other than the
    /// default one (Other Agents Only), none for Never. In colour while the agent is loaded; paused, the same icon without
    /// its colour (not see-through: a faded tile read wider than the others), so what's unloaded reads at a glance.
    func showIcon(_ session: Session) {
        let mode = app.settings[SettingKeys.agentIcons],
            image = app.catalog.icon(session.agent, size: 16)
        face.isHidden = mode != "always"
        markBox.isHidden = !face.isHidden
        face.image = session.status == .paused ? image.map(app.agentIcons.grey) : image
        face.alphaValue = session.status == .paused ? 0.7 : 1
        glyph.isHidden = mode != "others" || session.agent == app.catalog.defaultAgent
        let mark = glyph.isHidden ? nil : image.map(app.agentIcons.grey)
        if glyph.image !== mark { glyph.image = mark }
        glyph.toolTip = app.catalog.name(session.agent)
        glyph.setAccessibilityLabel(glyph.toolTip)
    }

    /// The slot's two looks, one shown (`showIcon`): the mark, or the logo with the mark in its corner.
    func lead() -> NSView {
        let view = NSView()
        markBox.addSubview(mark)
        for (child, side) in [(markBox, 16.0), (face, AgentFace.side)] as [(NSView, CGFloat)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.widthAnchor.constraint(equalToConstant: side),
                child.heightAnchor.constraint(equalToConstant: side),
                child.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                child.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: markBox.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markBox.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 16), view.heightAnchor.constraint(equalToConstant: 16)
        ])
        return view
    }

    /// The face's corner says what the row's mark would.
    func showFace(_ session: Session) {
        let faceMark = face.mark
        faceMark.status = mark.status
        faceMark.unread = mark.unread
        faceMark.limited = mark.limited
        faceMark.compacting = mark.compacting
        faceMark.waitsForCommand = mark.waitsForCommand
        faceMark.guessed = mark.guessed
        faceMark.progress = mark.progress
        face.cut()
    }

    /// VoiceOver reads the row as one sentence: "Fix login, needs your input, Asks: may I run npm test?, Atlas, now",
    /// not its mark, name, line and time one by one.
    func speak(_ session: Session) {
        let st = Self.shownStatus(session), project = app.projectName(app.worktree(session.worktreeId)?.repoId)
        let state = mark.isHidden ? nil : st.words
        let line = ask.isHidden ? nil : ask.stringValue, quiet = muted.isHidden ? nil : muted.toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            [title.stringValue, state, line, quiet, project, trailing.stringValue].compactMap { $0 }.filter {
                !$0.isEmpty
            }
            .joined(separator: ", "))
        mark.announces = false
        for part in [title, ask, trailing] as [NSView] { part.setAccessibilityElement(false) }
    }

    /// One line, as Mail lists mailboxes: an agent asking for you or done unseen is bold (isNews) and its mark says which;
    /// the colour stays on the mark (orange text on a light sidebar is 2:1). What it asks or did is on the hover card.
    func showState(_ session: Session) {
        title.textColor = session.status == .paused ? .secondaryLabelColor : .labelColor
        trailing.textColor = selected ? Self.onPill : .secondaryLabelColor
        toolTip = nil
    }

    /// A mark for the goal it works toward, else for what runs beside it, as on its tab, else for the machine it runs a
    /// command in (`kelp vm run`). Words have no room here: a name and a chip shared the same points, and a command mostly
    /// ended before it could be read. The tooltip and the card say them.
    func showChip(_ session: Session) {
        let beside = session.aside.count,
            mark = beside == 0 ? app.extensions.all.sessionMarks.lazy.compactMap({ $0(session) }).first : nil
        // Beside the dots there's no room for both it and the name: the card lists what it says.
        chip.isHidden = !family.isHidden || (session.goal == nil && beside == 0 && mark == nil)
        if let goal = session.goal {
            chip.show("scope")
            chip.toolTip = String(localized: "Goal: \(goal)")
        } else {
            chip.show(mark?.symbol ?? "apple.terminal", count: beside)
            chip.toolTip = mark?.tip ?? session.backgroundTip
        }
        chip.setAccessibilityLabel(chip.toolTip)
    }
}

extension SidebarCell {
    /// The folder this row stands for, if any (GitFolders.folder).
    var folder: Worktree? {
        switch node.kind {
        case .project(let id): app.gitState.folder(project: id)
        case .workspace(let id): app.gitState.folder(workspace: id)
        case .agent, .host, .parked: nil
        }
    }
    @objc func openChanges() {
        if let folder { app.workbench.open(TabURI.diff(folder.id), workspace: folder.id) }
    }
    @objc func openPR() {
        if let folder, let url = app.extensions.all.ci?.pr(folder.id)?.url {
            app.workbench.open(url, workspace: folder.id)
        }
    }
    @objc func openCI() { if let folder { app.extensions.all.ci?.open(folder.id) } }

    /// The stack shows a badge only when there's something to say, and drops it first when the row is narrow.
    func updateBadges() {
        let badgeFolder = app.settings[SettingKeys.gitBadges] ? folder : nil,
            stats = badgeFolder.flatMap { app.gitState.stats[$0.id] }
        let changeCounts = GitFolders.changes(stats)
        let prBadge = badgeFolder.flatMap { app.extensions.all.ci?.pr($0.id) }
        let sharedTip = badgeFolder.flatMap { GitFolders.sharedTip(app.gitState.shared($0.id)) }
        counts = changeCounts
        shares = sharedTip != nil
        showChanges()
        if changeCounts != nil || sharedTip != nil {
            let counted = stats.map {
                String(localized: "+\($0.totalAdded) −\($0.totalRemoved) not committed yet — click for the changes")
            }
            changes.toolTip = [sharedTip, changeCounts == nil ? nil : counted].compactMap { $0 }.joined(separator: "\n")
            changes.setAccessibilityLabel(changes.toolTip)
        }
        if let prBadge {
            pr.attributedTitle = prBadge.title
            pr.toolTip = prBadge.tip
        }
        let state = folder.flatMap { app.extensions.all.ci?.row($0.id) }
        ciMark.state = state
        ci.toolTip = folder.flatMap { app.extensions.all.ci?.line($0.id) }.map {
            $0 + "\n" + String(localized: "Click to open CI Runs")
        }
        ci.setAccessibilityLabel(ci.toolTip)
        hasBadge = (changeCounts != nil || sharedTip != nil, prBadge != nil, state != nil)
        fitBadges()
    }
    /// A quiet dot at rest; under the pointer the counts, on a pill as the PR's number is (bare they read as the name's).
    func showChanges() {
        let full = hovering ? counts : nil, title = full ?? Self.dot(shares ? .textOrange : .secondaryLabelColor)
        if changes.attributedTitle != title { changes.attributedTitle = title }
        changes.padding = full == nil ? 3 : Metrics.gap
        changes.restFill = full == nil ? nil : .fillRest
    }
    static func dot(_ color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: "•", attributes: [.font: NSFont.ui(TextSize.row, weight: .semibold), .foregroundColor: color])
    }

    /// Badges show while the name fits beside them: they step aside before it truncates (left to itself the stack
    /// squeezes the name instead: "kdrde…  +2 −1").
    func fitBadges() {
        guard let rowStack = changes.superview as? NSStackView else { return }
        let others = rowStack.views.filter { $0 !== changes && $0 !== pr && $0 !== ci && $0 !== stack && !$0.isHidden }
        var room = bounds.width - 2 - others.reduce(0) { $0 + max(0, $1.intrinsicContentSize.width) + rowStack.spacing }
        for (badge, has) in [(ci, hasBadge.ci), (changes, hasBadge.changes), (pr, hasBadge.pr)] {
            let need = badge.intrinsicContentSize.width + (badge === ci ? ciMark.overhang : 0) + rowStack.spacing,
                show = has && room >= need
            if show { room -= need }
            rowStack.setVisibilityPriority(show ? .mustHold : .notVisible, for: badge)
        }
        // The agents' logos take what's left: fewer of them, then none ("+N" counts the rest; the tooltip names all).
        let fits = (0...stack.count).last { stack.width(showing: $0) + rowStack.spacing <= room } ?? 0
        stack.cap = fits
        rowStack.setVisibilityPriority(fits > 0 ? .mustHold : .notVisible, for: stack)
    }
}
