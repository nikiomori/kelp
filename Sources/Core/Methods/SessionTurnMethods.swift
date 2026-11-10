import Foundation

// session.turn*: what an agent's turns changed, and undoing or redoing one.

/// → {turn, hasBase}: the files its last turn changed and how long it took; null when the session isn't running.
public struct SessionTurn: RPCMethod {
    public static let name = "session.turn"
    public var id: String
    public init(id: String) { self.id = id }
    /// One turn of the agent: what it changed by the time it stopped, and how long it worked.
    public struct Turn: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var path: String, added: Int, removed: Int
            public init(path: String, added: Int, removed: Int) {
                self.path = path
                self.added = added
                self.removed = removed
            }
        }
        public var files: [File], seconds: Double
        public init(files: [File], seconds: Double) {
            self.files = files
            self.seconds = seconds
        }
    }
    public struct Info: Codable, Sendable, Equatable {
        public var turn: Turn?, hasBase: Bool
        public init(turn: Turn?, hasBase: Bool) {
            self.turn = turn
            self.hasBase = hasBase
        }
    }
    public typealias Result = Info?
}
/// The session's turns, the newest first (the last 20): how its folder was as each began, with the prompt that started
/// it. None for a remote project's, where no snapshots are taken.
public struct SessionTurns: RPCMethod {
    public static let name = "session.turns"
    public typealias Result = [Mark]
    public var id: String
    public init(id: String) { self.id = id }
    /// A turn's start: `tree` is the folder then (a snapshot in the project's git, which git's cleanup may take after
    /// two weeks), `head` its HEAD then.
    public struct Mark: Codable, Sendable, Equatable, Identifiable {
        public var id: String, session: String, tree: String, head: String?, folder: String, prompt: String, at: Date
        public init(
            id: String = UUID().uuidString, session: String, tree: String, head: String?, folder: String,
            prompt: String,
            at: Date = Date()
        ) {
            self.id = id
            self.session = session
            self.tree = tree
            self.head = head
            self.folder = folder
            self.prompt = prompt
            self.at = at
        }
    }
}

/// A turn of the agent's undone: its folder put back as it was when `turn` began. Without `apply`, what would go back
/// and the folder's state now; with it, done only while the folder is still that `state`, answering with the state after
/// (for `session.turnRedo`). Refused while the agent works,
/// after commits since the turn began, and with another agent in the folder. `.env` files stay as they are.
public struct SessionTurnUndo: RPCMethod {
    public static let name = "session.turnUndo"
    public typealias Result = Plan
    public var id: String, turn: String, apply: Bool?, state: String?
    public init(id: String, turn: String, apply: Bool? = nil, state: String? = nil) {
        self.id = id
        self.turn = turn
        self.apply = apply
        self.state = state
    }
    public struct Plan: Codable, Sendable, Equatable {
        public var files: [String], state: String
        public init(files: [String], state: String) {
            self.files = files
            self.state = state
        }
    }
}

/// The last `session.turnUndo` taken back: the folder as it was before it, while it is still `state` (the Plan that
/// undo answered with). `turn` is the one that was undone.
public struct SessionTurnRedo: RPCMethod {
    public static let name = "session.turnRedo"
    public typealias Result = Done
    public var id: String, turn: String, state: String
    public init(id: String, turn: String, state: String) {
        self.id = id
        self.turn = turn
        self.state = state
    }
}
