// A sidebar row's marks: the folder's changes, the PR and CI badges, and an agent's icon, face, state and chip.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension SidebarCell {
    /// Shows the agent's icon. It goes before the name when Agent icons is Always, as a grey glyph after the name for
    /// an agent other than the default one (Other Agents Only), and not at all for Never. The icon is in colour while
    /// the agent is loaded. A paused agent gets the same icon without its colour (not see-through, because a faded tile
    /// read wider than the others), so what's unloaded reads at a glance.
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

    /// Makes the slot's two looks, of which `showIcon` shows one: the mark, or the logo with the mark in its corner.
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

    /// Sets the mark in the face's corner to say what the row's mark would.
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
        let st = session.shownStatus, project = app.projectName(app.worktree(session.worktreeId)?.repoId)
        let state = mark.isHidden ? nil : st.words
        let line = ask.isHidden ? nil : ask.stringValue, quiet = muted.isHidden ? nil : muted.toolTip
        say([title.stringValue, state, line, quiet, project, trailing.stringValue])
        mark.announces = false
        for part in [title, ask, trailing] as [NSView] { part.setAccessibilityElement(false) }
    }

    /// Makes the row one sentence for VoiceOver, of the parts it has. A project's row says its name and its tooltip
    /// with this. On a project's and a group's row the name stays a field of its own, because it is renamed in place.
    func say(_ parts: [String?]) {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// A group's row as a sentence: "feat, Branch, 2 chats". The count is the one the row shows while it is open.
    func speakGroup(onBranch: Bool) {
        let chats = node.children.isEmpty ? nil : String(localized: "\(node.children.count) chats")
        say([title.stringValue, onBranch ? String(localized: "Branch") : String(localized: "Group"), chats])
    }

    /// Styles the row as one line, as Mail lists mailboxes. An agent asking for you, or done and unseen, is bold
    /// (isNews), and its mark says which. The colour stays on the mark, because orange text on a light sidebar is 2:1.
    /// What the agent asks or did is on the hover card.
    func showState(_ session: Session) {
        title.textColor = session.status == .paused ? .secondaryLabelColor : .labelColor
        trailing.textColor = selected ? Self.onPill : .secondaryLabelColor
        toolTip = nil
    }

    /// Shows a chip for the goal the agent works toward, or else for what runs beside it (as on its tab), or else for
    /// the machine it runs a command in (`kelp vm run`). The chip has no words, because a name and a chip shared the
    /// same points, and a command mostly ended before it could be read. The tooltip and the card say them.
    func showChip(_ session: Session) {
        let beside = session.aside.count,
            mark = beside == 0 ? app.extensions.rowMarks(.agent(session.id)).first(where: { $0.place == .chip }) : nil
        // Beside the dots there's no room for both the chip and the name, so the chip hides and the card lists what it
        // says.
        chip.isHidden = !family.isHidden || (session.goal == nil && beside == 0 && mark == nil)
        if let goal = session.goal {
            chip.show("scope")
            chip.toolTip = String(localized: "Goal: \(goal)")
        } else {
            chip.show(mark?.symbol ?? "terminal", count: beside)
            chip.toolTip = mark?.tip ?? session.backgroundTip
        }
        chip.setAccessibilityLabel(chip.toolTip)
    }
}

extension SidebarCell {
    /// The folder this row stands for, if any (GitFolders.folder), whose marks it shows: a project's own folder on
    /// the project's row, or on its own screen's row once that has one; a screen's on its branch; a chat's own branch
    /// (SidebarItem.branch).
    var folder: Worktree? {
        switch node.kind {
        case .project(let id):
            node.children.contains { $0.kind == .workspace(node.workspace ?? "") } ? nil : app.gitFolder(project: id)
        case .workspace(let id): if isOwnScreen { app.worktree(id) } else { app.gitFolder(workspace: id) }
        case .agent: node.branch.flatMap { app.worktree($0) }   // not `app.worktree`: that picks worktree(holding:)
        case .host, .parked: nil
        }
    }
    @objc func openChanges() {
        if let folder { app.workbench.open(TabURI.diff(folder.id), workspace: folder.id) }
    }
    /// Opens the PR's tab, and with ⌘ held its page in the browser. A ⌘-click on the CI mark opens the run's page
    /// the same way (`FolderCI.open`).
    @objc func openPR() {
        guard let folder, let mark = app.extensions.all.ci?.pr(folder.id) else { return }
        if EditorArea.commandClick, let page = mark.page { return PreviewLinks.openOutside(page) }
        app.workbench.open(mark.uri, workspace: folder.id)
    }
    @objc func openCI() { if let folder { app.extensions.all.ci?.open(folder.id) } }
    /// The tooltip's line for a ⌘-click on the PR and CI marks.
    static var onGitHub: String { String(localized: "⌘-click: open on \("GitHub")") }

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
        // A chat's own branch with no PR yet shows the branch, with the commits it holds, in the PR's place.
        let branch = prBadge == nil && badgeFolder != nil && node.branch != nil ? badgeFolder : nil
        pr.action = branch == nil ? #selector(openPR) : #selector(openChanges)
        // Bare, as the changes dot is: a plate would make it read as a PR's number, and take a name's room.
        pr.restFill = branch == nil ? .fillRest : nil
        pr.padding = branch == nil ? Metrics.gap : Metrics.iconGap
        if let prBadge {
            pr.attributedTitle = prBadge.title
            pr.toolTip = prBadge.tip + "\n" + Self.onGitHub
            pr.setAccessibilityLabel(prBadge.tip)
        } else if let branch {
            let commits = app.gitState.ownWork(branch.id)?.commits ?? 0
            pr.attributedTitle = .signed(
                "arrow.triangle.branch", commits > 0 ? commits : nil, size: TextSize.caption,
                color: .secondaryLabelColor)
            pr.toolTip = String(
                localized: "This chat works on its own branch, \(branch.branch) — click for its changes")
            pr.setAccessibilityLabel(pr.toolTip)
        }
        let state = folder.flatMap { app.extensions.all.ci?.row($0.id) }
        ciMark.state = state
        ci.toolTip = folder.flatMap { app.extensions.all.ci?.line($0.id) }.map {
            [$0, String(localized: "Click to open CI Runs"), Self.onGitHub].joined(separator: "\n")
        }
        ci.setAccessibilityLabel(ci.toolTip)
        hasBadge = (changeCounts != nil || sharedTip != nil, prBadge != nil || branch != nil, state != nil)
        fitBadges()
    }
    /// Shows the changes as a quiet dot at rest. Under the pointer it shows the counts on a pill, as the PR's number is
    /// shown, because bare counts read as part of the name.
    func showChanges() {
        let full = spelling === changes ? counts : nil, title = full ?? Self.dot(shared: shares)
        if changes.attributedTitle != title { changes.attributedTitle = title }
        changes.padding = full == nil ? Metrics.iconGap : Metrics.gap
        changes.restFill = full == nil ? nil : .fillRest
    }
    /// The grey changes dot, two dots 2 pt apart when another folder changes the same files. That is a state to see,
    /// not a call to answer, so its form tells it, not orange. It is drawn (`circle.fill`), not a typed "•", so it is
    /// round and the same size in every look's typeface. The window bar's branch shows it too. One string per kind is
    /// kept while the font stays, so a row that redraws with no change doesn't take a new title.
    static func dot(shared: Bool) -> NSAttributedString {
        let font = NSFont.ui(TextSize.row, weight: .semibold)
        if let made = madeDots[shared], made.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font {
            return made
        }
        let size = TextSize.of(Metrics.gap), text = NSMutableAttributedString()
        for _ in 0..<(shared ? 2 : 1) {
            let dot = NSTextAttachment()
            dot.image = NSImage.symbol("circle.fill").withSymbolConfiguration(
                .init(pointSize: Metrics.iconTiny, weight: Metrics.iconWeight))
            // On the letters' middle: an attachment stands on the baseline otherwise.
            dot.bounds = NSRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
            text.append(NSAttributedString(attachment: dot))
        }
        if shared { text.addAttribute(.kern, value: Metrics.iconGap, range: NSRange(location: 0, length: 1)) }
        text.addAttributes(
            [.font: font, .foregroundColor: NSColor.secondaryLabelColor],
            range: NSRange(location: 0, length: text.length))
        madeDots[shared] = text
        return text
    }
    private static var madeDots: [Bool: NSAttributedString] = [:]

    /// Shows the badges only while the name fits beside them, so they step aside before the name truncates. Left to
    /// itself, the stack squeezes the name instead ("kdrde…  +2 −1").
    func fitBadges() {
        guard let rowStack = changes.superview as? NSStackView else { return }
        let others = rowStack.views.filter { $0 !== changes && $0 !== pr && $0 !== ci && $0 !== stack && !$0.isHidden }
        // Use the fitting size, not the intrinsic size. The slot and the "+" are sized by constraints and have no
        // intrinsic width, so with the intrinsic size the name lost their room to the marks ("K…").
        var room = bounds.width - 2 - others.reduce(0) { $0 + $1.fittingSize.width + rowStack.spacing }
        let gap = rowStack.spacing
        func take(_ badge: NSView, _ has: Bool, _ need: CGFloat) {
            let show = has && (room >= need + gap || badge === spelling)
            if show { room -= need + gap }
            rowStack.setVisibilityPriority(show ? .mustHold : .notVisible, for: badge)
        }
        // Room goes first to what stays longest: a failed CI, then the chats (one logo, or else their count, with all
        // of them named in the tooltip), the changes, the PR, and last the second logo.
        take(ci, hasBadge.ci, ci.intrinsicContentSize.width + ciMark.overhang)
        var logos = stack.total == 0 ? nil : [min(1, stack.count), 0].first { stack.width(showing: $0) + gap <= room }
        if let least = logos { room -= stack.width(showing: least) + gap }
        // On a chat, its branch's mark (or its PR) is what the row is about, so it keeps its room before the dot.
        if case .agent = node.kind {
            take(pr, hasBadge.pr, pr.intrinsicContentSize.width)
            take(changes, hasBadge.changes, changes.intrinsicContentSize.width)
        } else {
            take(changes, hasBadge.changes, changes.intrinsicContentSize.width)
            take(pr, hasBadge.pr, pr.intrinsicContentSize.width)
        }
        if let least = logos {
            logos = (least...max(least, stack.count)).last {
                stack.width(showing: $0) - stack.width(showing: least) <= room
            }
        }
        stack.cap = logos ?? 0
        rowStack.setVisibilityPriority(logos == nil ? .notVisible : .mustHold, for: stack)
    }
}
