import Foundation

// The session.turn* methods: what an agent's turns changed, and undoing or redoing a turn.

/// Returns {turn, hasBase}: the files the session's last turn changed and how long it took. null when the session
/// isn't running.
public struct SessionTurn: RPCMethod {
    public static let name = "session.turn"
    public var id: String
    public init(id: String) { self.id = id }
    /// One turn of the agent: what it had changed by the time it stopped, and how long it worked.
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
/// Returns the session's last 20 turns, newest first, each with how the folder was when the turn began and the prompt
/// that started it. Empty for a remote project, where no snapshots are taken.
public struct SessionTurns: RPCMethod {
    public static let name = "session.turns"
    public typealias Result = [Mark]
    public var id: String
    public init(id: String) { self.id = id }
    /// The start of a turn. `tree` is the folder as it was then (a snapshot in the project's git, which git's cleanup
    /// may remove after two weeks), and `head` is the folder's HEAD then.
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

/// Undoes one of the agent's turns by putting the folder back as it was when `turn` began. Without `apply`, it returns
/// what would go back and the folder's state now. With `apply`, it undoes only while the folder is still at that
/// `state`, and returns the state afterwards (for `session.turnRedo`). It is refused while the agent works, when there
/// are commits since the turn began, and when another agent is in the folder. `.env` files stay as they are.
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

/// Takes back the last `session.turnUndo`, putting the folder back as it was before the undo. It works only while the
/// folder is still at `state` (from the Plan the undo answered with). `turn` is the turn that was undone.
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
