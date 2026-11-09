// The hover card's SwiftUI views: the card, its worktree sizes and its context window.
import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.ui(13, weight: .semibold)).lineLimit(2)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let host = model.server, let servers = model.app.extensions.all.servers {
                servers.section(host, model.closeCard)
            }
            if let repo = model.repo { WorktreeSizes(items: model.worktrees, root: repo.path) }
            if let folder = model.folder, let pr = model.app.extensions.all.ci?.card(folder) { pr }
            if let changes = model.changes, changes.totalAdded + changes.totalRemoved > 0 {
                (Text("Not committed  ")
                    + Text(changes.totalAdded > 0 ? "+\(changes.totalAdded)" : "").foregroundColor(.textGreen)
                    + Text(changes.totalAdded > 0 && changes.totalRemoved > 0 ? " " : "")
                    + Text(changes.totalRemoved > 0 ? "−\(changes.totalRemoved)" : "").foregroundColor(.textRed))
                    .font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { agent in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusIcon(status: agent.session.markStatus, waitsForCommand: agent.session.waitsForCommand)
                            .font(
                                .ui(11))
                        Text(model.agentOnly ? agent.session.statusWords : model.app.catalog.displayName(agent.session))
                            .font(
                                .ui(12)
                            ).lineLimit(1)
                        if !model.agentOnly {
                            Text(agent.session.statusWords).font(.ui(11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(shortAgo(agent.session.statusAt ?? agent.session.createdAt)).font(
                            .ui(11).monospacedDigit()
                        )
                        .foregroundStyle(.tertiary)
                    }
                    if !agent.session.summary.isEmpty {
                        Text(Self.linked(agent.session.summary)).font(.ui(11)).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let goal = agent.session.goal {
                        Text("Goal: \(goal)").font(.ui(11)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let quietSince = agent.session.quietSince, agent.session.status == .working {
                        Text("No news for \(shortSpan(Date().timeIntervalSince(quietSince)))").font(.ui(11))
                            .foregroundStyle(
                                .secondary)
                    }
                    if agent.session.guessed == true, [.working, .done].contains(agent.session.status) {
                        Text("Read off the screen: a guess, so Kelp won't call it done or notify").font(.ui(11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let elsewhere = agent.session.workingElsewhere {
                        Text(elsewhere).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if model.agentOnly, let browser = agent.session.browser {
                        Text("Browser \(BrowserSkillWords.line(browser))").font(.ui(11)).foregroundStyle(.tertiary)
                            .lineLimit(
                                1)
                    }
                }
                AgentWork(model: model, id: agent.id)
                if QuickReply.fits(agent.session) {
                    HStack(spacing: 6) {
                        ForEach(QuickReply.all) { reply in
                            Button(reply.title) { model.reply(reply.text, to: agent.id) }.controlSize(.small)
                        }
                    }
                }
            }
            if !model.pages.isEmpty, let runs = model.app.extensions.all.runs {
                HStack(spacing: 8) {
                    ForEach(model.pages, id: \.port) { page in
                        Button(page.address) { runs.open(page, model.workspaceId) }
                            .buttonStyle(PointerButtonStyle()).font(.ui(11).monospacedDigit()).foregroundStyle(
                                Color.accentColor)
                    }
                }
            }
            if let until = model.app.arrangement.mutedUntil(model.muteIds) {
                HStack(spacing: 8) {
                    Text(Mutes.line(until: until)).font(.ui(11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Unmute") { model.app.arrangement.mute(model.muteIds, until: nil) }.controlSize(.small)
                }
            }
            if let turn = model.turn { Text(turn).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary) }
            if let usage = model.context { ContextBlock(model: model, used: usage.used, window: usage.window) }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// An agent's summary often ends with a Markdown link ("Plan ready: [Plan](https://…)"): its words, clickable.
    static func linked(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch { return AttributedString(text) }   // not Markdown: as written
    }
}

/// "Worktrees 20.1 GB" over the biggest ones, named inside the project when they're in it (`.claude/worktrees/…`).
struct WorktreeSizes: View {
    let items: [RepoWorktreeSizes.Item]?, root: String
    var body: some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Worktrees")
                    Spacer(minLength: 8)
                    Text(Self.size(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                }.font(.ui(12))
                ForEach(items.prefix(8), id: \.path) { worktree in
                    HStack(spacing: 6) {
                        Text(Self.name(worktree.path, root: root)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.size(worktree.bytes)).monospacedDigit()
                    }.font(.ui(11)).foregroundStyle(.secondary)
                }
                if items.count > 8 { Text("\(items.count - 8) more").font(.ui(11)).foregroundStyle(.tertiary) }
            }
        } else {
            (items == nil ? Text("Measuring worktrees…") : Text("No other git worktrees")).font(.ui(11))
                .foregroundStyle(.secondary)
        }
    }
    static func name(_ path: String, root: String) -> String {
        path.hasPrefix(root + "/")
            ? String(path.dropFirst(root.count + 1)) : (path as NSString).abbreviatingWithTildeInPath
    }
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// How full the agent's conversation is, and what filled it under a click, remembered: it's a long table, so it stays out
/// of the way until someone wants it, or until Compact Now, which stands in it, is an answer.
struct ContextBlock: View {
    let model: CardModel, used: Int, window: Int
    @AppStorage("sidebar.card.contextOpen") private var opened = false

    var body: some View {
        let open = opened || model.compact != nil
        VStack(alignment: .leading, spacing: 6) {
            Button {
                opened.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.symbol(Metrics.iconTiny)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    ContextLine(used: used, window: window)
                }
            }
            .buttonStyle(PointerButtonStyle()).padding(.horizontal, -4)
            if let cold = model.coldCache { Text(cold).font(.ui(11)).foregroundStyle(.secondary) }
            if open, let parts = model.parts { ContextParts(parts: parts, window: window, compact: model.compact) }
        }
        .task(id: open) { if open { await model.loadParts() } }
    }
}

/// How full the agent's conversation is; amber from three quarters, red from nine tenths.
struct ContextLine: View {
    let used: Int, window: Int
    var body: some View {
        let share = min(1, Double(used) / Double(max(1, window)))
        let color: Color = share >= 0.9 ? .red : share >= 0.75 ? .orange : .secondary
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: share).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }.frame(width: 11, height: 11)
            Text("Context \(Int(share * 100))% · \(used / 1000)k of \(window / 1000)k tokens").font(
                .ui(11).monospacedDigit()
            ).foregroundStyle(color)
        }
    }
}
