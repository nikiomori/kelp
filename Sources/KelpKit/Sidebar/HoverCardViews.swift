// The hover card's SwiftUI views: the card, its worktree sizes and its context window.
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(model.title).font(.ui(TextSize.heading, weight: .semibold)).lineLimit(2)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let when = model.closes?.formatted(.relative(presentation: .named)) {
                Text("Empty: it closes by itself \(when), unless something opens here.")
                    .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let host = model.server, let servers = model.app.extensions.all.servers {
                servers.section(host, model.closeCard)
            }
            if let repo = model.repo { WorktreeSizes(items: model.worktrees, root: repo.path) }
            if let branch = model.branch { OwnBranch(model: model, branch: branch) }
            if let folder = model.folder, let pr = model.app.extensions.all.ci?.card(folder) { pr }
            if let changes = model.changes, changes.totalAdded + changes.totalRemoved > 0 {
                (Text("Not committed  ")
                    + Text(changes.totalAdded > 0 ? "+\(changes.totalAdded)" : "").foregroundColor(.textGreen)
                    + Text(changes.totalAdded > 0 && changes.totalRemoved > 0 ? " " : "")
                    + Text(changes.totalRemoved > 0 ? "−\(changes.totalRemoved)" : "").foregroundColor(.textRed))
                    .font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                if let screen = model.heading(at: index) {
                    Text(screen).font(.ui(TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    HStack(spacing: Metrics.gap) {
                        StatusIcon(status: agent.markStatus, of: agent)
                            .font(
                                .ui(TextSize.caption))
                        Text(model.agentOnly ? agent.statusWords : model.app.catalog.displayName(agent))
                            .font(
                                .ui(TextSize.row)
                            ).lineLimit(1)
                        if !model.agentOnly {
                            Text(agent.statusWords).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Metrics.gapWide)
                        Text(shortAgo(agent.statusAt ?? agent.createdAt)).font(
                            .ui(TextSize.caption).monospacedDigit()
                        )
                        .foregroundStyle(.secondary)
                    }
                    if !agent.summary.isEmpty {
                        Text(Self.linked(agent.summary)).font(.ui(TextSize.row)).foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let goal = agent.goal {
                        Text("Goal: \(goal)").font(.ui(TextSize.row)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let quietSince = agent.quietSince, agent.status == .working {
                        Text("No news for \(shortSpan(Date().timeIntervalSince(quietSince)))").font(
                            .ui(TextSize.caption)
                        )
                        .foregroundStyle(
                            .secondary)
                    }
                    if agent.guessed == true, [.working, .done].contains(agent.status) {
                        Text("Read off the screen: a guess, so Kelp won’t call it done or notify").font(
                            .ui(TextSize.caption)
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let elsewhere = agent.workingElsewhere {
                        Text(elsewhere).font(.ui(TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if model.agentOnly {
                    let close: @MainActor () -> Void = { [model] in model.closeCard() }
                    let parts = model.app.extensions.all.agentCards.compactMap { $0(agent, close) }
                    ForEach(parts.indices, id: \.self) { parts[$0] }
                }
                AgentWork(model: model, id: agent.id)
                if QuickReply.fits(agent) {
                    HStack(spacing: Metrics.gap) {
                        ForEach(QuickReply.all) { reply in
                            Button(reply.title) { model.reply(reply.text, to: agent.id) }.controlSize(.small)
                        }
                    }
                }
            }
            if !model.pages.isEmpty, let runs = model.app.extensions.all.runs {
                HStack(spacing: Metrics.gapWide) {
                    ForEach(model.pages, id: \.port) { page in
                        Button(page.address) { runs.open(page, model.workspaceId) }
                            .buttonStyle(.kelpLink).font(.ui(TextSize.caption).monospacedDigit())
                    }
                }
            }
            if let until = model.app.arrangement.mutedUntil(model.muteIds) {
                HStack(spacing: Metrics.gapWide) {
                    Text(Mutes.line(until: until)).font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                    Spacer(minLength: Metrics.gapWide)
                    Button("Unmute") { model.app.arrangement.mute(model.muteIds, until: nil) }.controlSize(.small)
                }
            }
            if let turn = model.turn {
                Text(turn).font(.ui(TextSize.caption).monospacedDigit()).foregroundStyle(.secondary)
            }
            if let usage = model.context { ContextBlock(model: model, used: usage.used, window: usage.window) }
        }
        .padding(Metrics.inset)
        .frame(width: 300, alignment: .leading)
    }

    /// An agent's summary often ends with a Markdown link ("Plan ready: [Plan](https://…)"). This makes the link's
    /// words clickable.
    static func linked(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch { return AttributedString(text) }   // not Markdown, so shown as written
    }
}

/// "Worktrees 20.1 GB" above the biggest worktrees. Worktrees inside the project are named by their path in it
/// (`.claude/worktrees/…`).
struct WorktreeSizes: View {
    let items: [RepoWorktreeSizes.Item]?, root: String
    var body: some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                HStack {
                    Text("Worktrees")
                    Spacer(minLength: Metrics.gapWide)
                    Text(Self.size(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                }.font(.ui(TextSize.row))
                ForEach(items.prefix(8), id: \.path) { worktree in
                    HStack(spacing: Metrics.gap) {
                        Text(Self.name(worktree.path, root: root)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Metrics.gapWide)
                        Text(Self.size(worktree.bytes)).monospacedDigit()
                    }.font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                if items.count > 8 {
                    Text("\(items.count - 8) more").font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
            }
        } else {
            (items == nil ? Text("Measuring worktrees…") : Text("No other git worktrees")).font(.ui(TextSize.caption))
                .foregroundStyle(.secondary)
        }
    }
    static func name(_ path: String, root: String) -> String {
        Paths.relative(path, to: root) ?? (path as NSString).abbreviatingWithTildeInPath
    }
    static func size(_ bytes: Int) -> String {
        DesignKit.bytes(bytes, file: true)
    }
}

/// How full the agent's conversation is, and, under a click that is remembered, what filled it. That is a long table,
/// so it stays out of the way until someone wants it, or until Compact Now, which stands in it, is an answer.
struct ContextBlock: View {
    let model: CardModel, used: Int, window: Int
    @AppStorage("sidebar.card.contextOpen") private var opened = false
    /// Parts not read yet show as their outline at once, held 0.4 s so a quick read doesn't blink; then the outline
    /// fades into the parts and the bar fills (`grow`). Parts the card already has stand at once.
    @State private var waiting = false
    @State private var arrived = false

    var body: some View {
        let open = opened || model.compact != nil
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Button {
                // The chevron turns and the parts come and go as a fold does (`soft`).
                withAnimation(Motion.reduced ? nil : .timingCurve(0.25, 0.8, 0.25, 1, duration: Motion.fold)) {
                    opened.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    ContextLine(used: used, window: window)
                }
            }
            .buttonStyle(PointerButtonStyle(flush: true))
            if let cold = model.coldCache { Text(cold).font(.ui(TextSize.caption)).foregroundStyle(.secondary) }
            if open, !waiting, let parts = model.parts {
                ContextParts(parts: parts, window: window, compact: model.compact, grow: arrived)
                    .transition(.opacity)
            } else if open, waiting {
                ContextPartsOutline().transition(.opacity)
            }
        }
        .task(id: open) { if open { await load() } }
    }

    private func load() async {
        guard model.parts == nil else { return }
        waiting = true
        let began = Date.now
        await model.loadParts()
        let left = LoadingView.held - Date.now.timeIntervalSince(began)
        if left > 0 { do { try await Task.sleep(for: .seconds(left)) } catch { return } }
        withAnimation(.easeOut(duration: Motion.duration(Motion.appear))) {
            waiting = false
            arrived = true
        }
    }
}

/// How full the agent's conversation is: the tab's own pie (`ContextMeter`), so the two never disagree in shape or
/// colour; the words take the text shade of its colour.
struct ContextLine: View {
    let used: Int, window: Int
    var body: some View {
        let share = min(1, Double(used) / Double(max(1, window)))
        let level = ContextMeter.level(.init(used: used, window: window))
        HStack(spacing: Metrics.gap) {
            ContextPie(usage: .init(used: used, window: window)).frame(width: 12, height: 12)
            Text("Context \(Int(share * 100))% · \(used / 1000)k of \(window / 1000)k tokens").font(
                .ui(TextSize.caption).monospacedDigit()
            ).foregroundStyle(Color(nsColor: ContextMeter.textColor(level)))
        }
    }
}

/// The tab's pie in the card. The card shows it at every level, where the tab waits for the first; the words beside
/// it say the level, so VoiceOver reads them, not the pie.
private struct ContextPie: NSViewRepresentable {
    let usage: SessionContextWindow.Usage
    func makeNSView(context: Context) -> ContextMeter {
        let pie = ContextMeter()
        pie.setAccessibilityElement(false)
        return pie
    }
    func updateNSView(_ pie: ContextMeter, context: Context) {
        pie.usage = usage
        pie.isHidden = false
    }
}

/// On a chat's card, the branch the chat works on in a folder of its own: its name, what it holds that the base
/// branch doesn't, and a button to its changes. Its PR and what isn't committed follow, as on a group's card.
struct OwnBranch: View {
    let model: CardModel
    let branch: Worktree

    var body: some View {
        let base = model.app.repo(branch.repoId)?.baseBranch ?? "main"
        let commits = model.app.gitState.ownWork(branch.id)?.commits ?? 0
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            HStack(spacing: Metrics.gap) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(branch.branch).font(.ui(TextSize.row)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Metrics.gapWide)
                Button("Changes") {   // on the chat's screen, as its row's mark opens them: the branch has no row
                    model.app.workbench.open(TabURI.diff(branch.id), workspace: model.workspaceId)
                    model.closeCard()
                }
                .controlSize(.small)
            }
            Text(
                commits > 0
                    ? "Its own branch: \(commits) commits not on \(base) yet" : "Its own branch, cut from \(base)"
            )
            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
            Text((branch.path as NSString).abbreviatingWithTildeInPath).font(.ui(TextSize.caption))
                .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
    }
}
