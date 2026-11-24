import Foundation

/// A mark the user puts on an agent's page (Mark in its bar): what it points at and what should change. A mark lives
/// until the user says it's done. It is a draft until sent, then the agent's while its turn runs, then the user's to
/// check (what the agent did to the marked thing, against the version it was sent with), then done or sent again. Its
/// number stays the same throughout, so the user and the agent both say "#3" for it.
public struct ArtifactMark: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// An element of a board, by its `data-id` (or its tag when it has none).
        case element
        /// A rectangle drawn on a board, and a stroke drawn on it. Both come with a picture of that part of the board.
        case area, pen
        /// Text selected on a doc or slides, found again by its words.
        case quote
    }
    public enum State: String, Codable, CaseIterable, Sendable {
        case draft
        /// Sent to an agent, whose turn hasn't ended yet.
        case sent
        /// The agent's turn ended: the user checks what it did.
        case check
        case done
    }
    /// What the agent's turn did to the marked thing.
    public enum Outcome: String, Codable, CaseIterable, Sendable { case changed, same, gone }

    /// One sending of the mark: the note it went with, and what came of it.
    public struct Round: Codable, Equatable, Sendable {
        public var note: String
        /// When it was sent, in seconds since 1970, and the chat it went to.
        public var at: Double
        public var to: String?
        /// The version of the page it was sent with, and the version the agent's turn left.
        public var before: Int?, after: Int?
        public var outcome: Outcome?
        /// What the agent said about this mark (`kelp artifact reply`).
        public var reply: String?
        public init(
            note: String, at: Double, to: String? = nil, before: Int? = nil, after: Int? = nil,
            outcome: Outcome? = nil, reply: String? = nil
        ) {
            self.note = note
            self.at = at
            self.to = to
            self.before = before
            self.after = after
            self.outcome = outcome
            self.reply = reply
        }
    }

    public var id: Int
    public var kind: Kind
    /// The board's file (`boards/A.html`), empty on a doc.
    public var board: String
    /// The element: `[data-id=title]`, or its tag. For an area or a stroke, the element it starts on.
    public var target: String
    /// The start of the element's text, or the quoted words.
    public var text: String
    /// An area's x, y, width and height in the board's own pixels.
    public var area: [Double]?
    /// A stroke as an SVG path in the board's own pixels.
    public var path: String?
    /// The picture of an area or a stroke, or of a motion page's frame, relative to the page's folder
    /// (`marks/2.png`).
    public var picture: String?
    /// On a motion page, the second of the video it was made at.
    public var time: Double?
    /// The agent's question, when the agent put the mark (`kelp artifact ask`): the user's note answers it.
    public var asked: String?
    /// The note the user is writing now: a draft's note, empty once sent.
    public var note: String
    public var state: State
    public var rounds: [Round]

    public init(
        id: Int = 0, kind: Kind = .element, board: String = "", target: String = "", text: String = "",
        area: [Double]? = nil, path: String? = nil, picture: String? = nil, time: Double? = nil, note: String = "",
        state: State = .draft, rounds: [Round] = [], asked: String? = nil
    ) {
        self.asked = asked
        self.time = time
        self.id = id
        self.kind = kind
        self.board = board
        self.target = target
        self.text = text
        self.area = area
        self.path = path
        self.picture = picture
        self.note = note
        self.state = state
        self.rounds = rounds
    }

    /// The `data-id` the mark points at, when its target is one.
    public var elementID: String? {
        guard target.hasPrefix("[data-id="), target.hasSuffix("]") else { return nil }
        return String(target.dropFirst(9).dropLast())
    }
}

/// A change the user made to a board by hand (Edit), kept until it goes to the agent with the next marks.
public struct HandEdit: Codable, Equatable, Sendable {
    public var board: String, id: String
    /// `text`, or the style property or tweak changed.
    public var what: String
    public var from: String?, to: String?
    public init(board: String, id: String, what: String, from: String?, to: String?) {
        self.board = board
        self.id = id
        self.what = what
        self.from = from
        self.to = to
    }
}

/// A page's marks, kept in `notes.json` beside it, and the hand edits waiting to go with them.
public struct ArtifactMarks: Codable, Equatable, Sendable {
    public static let file = "notes.json"
    /// The folder of the marks' pictures, beside the page.
    public static let pictures = "marks"

    /// The number the next mark gets.
    public var next: Int
    public var marks: [ArtifactMark]
    public var edits: [HandEdit]
    /// What the agent suggests the user asks next, shown under the marks until the next send.
    public var suggestions: [String] = []

    public init(next: Int = 1, marks: [ArtifactMark] = [], edits: [HandEdit] = []) {
        self.next = next
        self.marks = marks
        self.edits = edits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        marks = try c.decode([ArtifactMark].self, forKey: .marks)
        edits = try c.decodeIfPresent([HandEdit].self, forKey: .edits) ?? []
        suggestions = try c.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        next = max(try c.decodeIfPresent(Int.self, forKey: .next) ?? 1, (marks.map(\.id).max() ?? 0) + 1)
    }

    /// Returns the marks in a `notes.json`. A file from before marks had numbers (a list of drafts) reads as those
    /// drafts. A file that doesn't read gives no marks.
    public static func read(_ data: Data?) -> ArtifactMarks {
        guard let data else { return ArtifactMarks() }
        struct Old: Decodable { var board: String, target: String, text: String, note: String }
        let decoder = JSONDecoder()
        do {
            guard data.first(where: { !Character(UnicodeScalar($0)).isWhitespace }) == UInt8(ascii: "[") else {
                return try decoder.decode(ArtifactMarks.self, from: data)
            }
            let marks = try decoder.decode([Old].self, from: data).enumerated().map { i, m in
                ArtifactMark(
                    id: i + 1, kind: m.board.isEmpty ? .quote : .element, board: m.board, target: m.target,
                    text: m.text, note: m.note)
            }
            return ArtifactMarks(next: marks.count + 1, marks: marks)
        } catch {
            return ArtifactMarks()   // a file that doesn't read holds no marks
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// How many marks are in each state, for the bar and the artifacts list.
    public var counts: [ArtifactMark.State: Int] { Dictionary(grouping: marks, by: \.state).mapValues(\.count) }

    /// What the window or an agent changes in the marks. The daemon applies each change to the file as it is then, so
    /// the window's drafts, an agent's reply and the end of a turn never write over each other.
    public struct Change: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            /// The window's drafts as they are now (`drafts`). Drafts not in the list are removed; a draft with id 0
            /// is new.
            case drafts
            /// Sends drafts `ids` to chat `to`, with the page at version `before`. Their hand edits go with them.
            case send
            /// The user is done with mark `id`, or wants it again (a draft once more, with what was said before).
            case done, again
            /// The agent's word (`text`) on mark `id`, from `kelp artifact reply`.
            case reply
            /// A change made by hand on a board (`edit`), kept for the next marks.
            case edit
            /// The agent asks about an element (`drafts`: the one mark, its `asked` set), from `kelp artifact ask`.
            case ask
            /// The agent's suggestions for what to ask next (`lines`, three at most), from `kelp artifact suggest`.
            case suggest
        }
        public var kind: Kind
        public var drafts: [ArtifactMark]?
        public var ids: [Int]?
        public var id: Int?
        public var to: String?
        public var before: Int?
        public var text: String?
        public var edit: HandEdit?
        public var lines: [String]?

        public init(
            _ kind: Kind, drafts: [ArtifactMark]? = nil, ids: [Int]? = nil, id: Int? = nil, to: String? = nil,
            before: Int? = nil, text: String? = nil, edit: HandEdit? = nil, lines: [String]? = nil
        ) {
            self.lines = lines
            self.kind = kind
            self.drafts = drafts
            self.ids = ids
            self.id = id
            self.to = to
            self.before = before
            self.text = text
            self.edit = edit
        }

        public static func drafts(_ list: [ArtifactMark]) -> Change { Change(.drafts, drafts: list) }
        public static func send(ids: [Int], to: String?, before: Int?) -> Change {
            Change(.send, ids: ids, to: to, before: before)
        }
        public static func done(id: Int) -> Change { Change(.done, id: id) }
        public static func again(id: Int) -> Change { Change(.again, id: id) }
        public static func reply(id: Int, text: String) -> Change { Change(.reply, id: id, text: text) }
        public static func edit(_ edit: HandEdit) -> Change { Change(.edit, edit: edit) }
        public static func ask(_ mark: ArtifactMark) -> Change { Change(.ask, drafts: [mark]) }
        public static func suggest(_ lines: [String]) -> Change { Change(.suggest, lines: lines) }
    }

    /// Applies `change` at time `now`. Returns false when it changes nothing (an unknown mark, or one in a state that
    /// doesn't take it).
    @discardableResult
    public mutating func apply(_ change: Change, now: Double = Date().timeIntervalSince1970) -> Bool {
        switch change.kind {
        case .drafts:
            var kept = marks.filter { $0.state != .draft }
            for var d in change.drafts ?? [] {
                d.state = .draft
                // A draft that was sent meanwhile is that sent mark now, not a new draft.
                if marks.contains(where: { $0.id == d.id && $0.state != .draft }) { continue }
                if d.id == 0 { d.id = next }
                next = max(next, d.id + 1)
                // A draft sent again keeps what was said before.
                if let old = marks.first(where: { $0.id == d.id }) { d.rounds = old.rounds }
                kept.append(d)
            }
            let changed = kept != marks
            marks = kept
            return changed
        case .send:
            let ids = change.ids ?? []
            var any = false
            for i in marks.indices where ids.contains(marks[i].id) && marks[i].state == .draft {
                marks[i].rounds.append(.init(note: marks[i].note, at: now, to: change.to, before: change.before))
                marks[i].note = ""
                marks[i].state = .sent
                any = true
            }
            if any { edits = [] }   // they went with these marks
            if any { suggestions = [] }   // and what was suggested before them was answered by them
            return any
        case .done:
            return set(change.id, from: [.check, .sent]) { $0.state = .done }
        case .again:
            return set(change.id, from: [.check, .done]) { $0.state = .draft }
        case .reply:
            let line = (change.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return false }
            return set(change.id, from: [.sent, .check]) { mark in
                guard !mark.rounds.isEmpty else { return }
                let said = mark.rounds[mark.rounds.count - 1].reply
                mark.rounds[mark.rounds.count - 1].reply = said.map { $0 + "\n" + line } ?? line
            }
        case .ask:
            guard var mark = change.drafts?.first, mark.asked?.isEmpty == false else { return false }
            mark.id = next
            mark.state = .draft
            next += 1
            marks.append(mark)
            return true
        case .suggest:
            let lines = (change.lines ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.prefix(3).map { String($0.prefix(200)) }
            guard lines != suggestions else { return false }
            suggestions = Array(lines)
            return true
        case .edit:
            guard let edit = change.edit else { return false }
            if let i = edits.firstIndex(where: { ($0.board, $0.id, $0.what) == (edit.board, edit.id, edit.what) }) {
                edits[i].to = edit.to   // the first `from` stays: it's what the agent last saw
                if edits[i].to == edits[i].from { edits.remove(at: i) }
            } else {
                edits.append(edit)
            }
            return true
        }
    }

    private mutating func set(
        _ id: Int?, from states: Set<ArtifactMark.State>, _ body: (inout ArtifactMark) -> Void
    ) -> Bool {
        guard let id, let i = marks.firstIndex(where: { $0.id == id }), states.contains(marks[i].state) else {
            return false
        }
        let was = marks[i]
        body(&marks[i])
        return marks[i] != was
    }

    /// Called when chat `session`'s turn ends. If the turn was the one that got this page's marks (its prompt holds
    /// `Marks on <page>`), each mark sent to that chat is the user's to check now, with what the turn did to it:
    /// `outcome` compares the marked thing in version `before` with the page as the turn left it (version `after`).
    /// A turn about something else leaves the marks with the agent. Returns whether anything changed.
    @discardableResult
    public mutating func turnEnded(
        session: String, prompt: String, page: String, after: Int?,
        outcome: (ArtifactMark, ArtifactMark.Round) -> ArtifactMark.Outcome
    ) -> Bool {
        guard prompt.contains("Marks on \(page)") else { return false }
        var any = false
        for i in marks.indices where marks[i].state == .sent {
            guard var round = marks[i].rounds.last, round.to == nil || round.to == session else { continue }
            round.after = after
            round.outcome = outcome(marks[i], round)
            marks[i].rounds[marks[i].rounds.count - 1] = round
            marks[i].state = .check
            any = true
        }
        return any
    }

    /// Returns what a turn did to `mark`'s thing: `before` and `after` are the board's text (or a doc's), nil when it
    /// isn't there.
    public static func outcome(of mark: ArtifactMark, before: String?, after: String?) -> ArtifactMark.Outcome {
        guard let after else { return .gone }
        if let id = mark.elementID {
            guard let now = BoardEdit.element(after, id: id) else { return .gone }
            return before.flatMap { BoardEdit.element($0, id: id) } == now ? .same : .changed
        }
        return before == after ? .same : .changed
    }
}

extension ArtifactMarks {
    private static let lock = NSLock()

    /// Reads the marks beside the page in `folder`, lets `body` change them, and writes them back, one change at a
    /// time. Returns the marks as written, or nil when `body` changed nothing.
    @discardableResult
    public static func update(in folder: URL, _ body: (inout ArtifactMarks) throws -> Bool) throws -> ArtifactMarks? {
        lock.lock()
        defer { lock.unlock() }
        let url = folder.appendingPathComponent(file)
        var marks = read(FileManager.default.contents(atPath: url.path))
        guard try body(&marks) else { return nil }
        try marks.encoded().write(to: url, options: .atomic)
        return marks
    }
}
