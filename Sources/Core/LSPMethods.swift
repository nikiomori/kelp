import Foundation

// Language servers live in the daemon: one per (project, server command), shared by every client, started for the first
// file a trusted project opens and stopped once none is open. The app says which server a file gets (its extensions'
// `languages`); the daemon decides whether one may run.

/// Where a symbol is defined.
public struct CodeLocation: Codable, Sendable, Equatable {
    public var path: String, line: Int, column: Int
    public init(path: String, line: Int, column: Int) { self.path = path; self.line = line; self.column = column }
}

/// An error or warning a language server found: from `line`, `column` to `endLine`, `endColumn`, all 0-based, in UTF-16 units.
public struct CodeProblem: Codable, Sendable, Equatable {
    public var line: Int, column: Int, endLine: Int, endColumn: Int, isError: Bool, message: String
    public init(line: Int, column: Int, endLine: Int, endColumn: Int, isError: Bool, message: String) {
        self.line = line; self.column = column; self.endLine = endLine; self.endColumn = endColumn; self.isError = isError; self.message = message
    }
}

/// One completion: what the list shows and what goes in.
public struct CodeCompletion: Codable, Sendable, Equatable {
    public var label: String, detail: String?, insert: String
    public init(label: String, detail: String? = nil, insert: String) { self.label = label; self.detail = detail; self.insert = insert }
}

/// Why no server runs for a file: what the app asks or offers (trust the project, install the server).
public enum LSPRefusal: Codable, Sendable, Equatable {
    /// A project's language servers run its own code (build scripts, Package.swift, its node_modules): not before the
    /// user trusts it in Kelp's window (`lsp.trusted`).
    case untrusted
    /// The server command isn't on the login shell's PATH.
    case notInstalled(String)

    public var error: RPCError {
        let message = switch self {
        case .untrusted: "This project isn't trusted to run its language servers."
        case .notInstalled(let c): "Language server \(c) isn't installed."
        }
        return RPCError(code: -32002, message: message, data: try? JSONValue.from(self))
    }
    /// The refusal a daemon's error carries, when it's this kind of error.
    public init?(_ error: Error) {
        guard let d = (error as? RPCError)?.data, let r = try? d.decode(LSPRefusal.self) else { return nil }
        self = r
    }
}

/// A file a tab shows, given to its server (started now when it isn't running). Fails with an `LSPRefusal` when no server
/// may run there. Each open is matched by an `LSPClose`; a connection that goes closes what it opened.
public struct LSPOpen: InternalMethod {
    public static let name = "lsp.open"; public typealias Result = Done
    /// The UI state key listing the projects the user trusted for language servers and formatters (only Kelp's window
    /// writes it).
    public static let trustKey = "lsp.trusted"
    public var root: String, path: String, languageId: String, command: String, args: [String]?, text: String
    public init(root: String, path: String, languageId: String, command: String, args: [String]? = nil, text: String) {
        self.root = root; self.path = path; self.languageId = languageId; self.command = command; self.args = args; self.text = text
    }
}
/// The file's whole text now (sent as a notification while typing).
public struct LSPChange: InternalMethod {
    public static let name = "lsp.change"; public typealias Result = Done
    public var root: String, path: String, text: String
    public init(root: String, path: String, text: String) { self.root = root; self.path = path; self.text = text }
}
/// A tab showing the file closed.
public struct LSPClose: InternalMethod {
    public static let name = "lsp.close"; public typealias Result = Done
    public var root: String, path: String
    public init(root: String, path: String) { self.root = root; self.path = path }
}
/// Positions are 1-based lines and columns.
public struct LSPDefinition: InternalMethod {
    public static let name = "lsp.definition"; public typealias Result = CodeLocation?
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) { self.root = root; self.path = path; self.line = line; self.column = column }
}
/// Completions at a position, 1-based.
public struct LSPCompletion: InternalMethod {
    public static let name = "lsp.completion"; public typealias Result = [CodeCompletion]
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) { self.root = root; self.path = path; self.line = line; self.column = column }
}
/// The innermost function, method, class or module around a line (Test at Cursor's `${symbol}`).
public struct LSPSymbol: InternalMethod {
    public static let name = "lsp.symbol"; public typealias Result = String?
    public var root: String, path: String, line: Int
    public init(root: String, path: String, line: Int) { self.root = root; self.path = path; self.line = line }
}

/// What the language server last said is wrong with the file at `path`. They reach a tab with its `FileEvent`.
public struct LSPProblems: InternalMethod {
    public static let name = "lsp.problems"; public typealias Result = [CodeProblem]
    public var path: String
    public init(path: String) { self.path = path }
}
