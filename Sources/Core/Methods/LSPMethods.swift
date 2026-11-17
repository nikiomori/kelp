import Foundation

// Language servers live in the daemon, one per (project, server command), shared by every client. A server starts for
// the first file a trusted project opens and stops once no file is open. The app says which servers a file gets (from
// the `languages` of its extensions: a language's own server and, beside it, a linter's). The daemon decides whether a
// server may run.

/// Where a symbol is defined.
public struct CodeLocation: Codable, Sendable, Equatable {
    public var path: String, line: Int, column: Int
    public init(path: String, line: Int, column: Int) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// An error or warning a language server found, from `line`, `column` to `endLine`, `endColumn`, all 0-based and in
/// UTF-16 units.
public struct CodeProblem: Codable, Sendable, Equatable {
    public var line: Int, column: Int, endLine: Int, endColumn: Int, isError: Bool, message: String
    public init(line: Int, column: Int, endLine: Int, endColumn: Int, isError: Bool, message: String) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.isError = isError
        self.message = message
    }
}

/// A name a file defines: what it is called, what it is ("class", "function"…) and its 1-based line.
/// `path` is the file, set in a project-wide list.
public struct CodeSymbol: Codable, Sendable, Equatable {
    public var name: String, kind: String, line: Int, path: String?
    public init(name: String, kind: String, line: Int, path: String? = nil) {
        self.name = name
        self.kind = kind
        self.line = line
        self.path = path
    }
}

/// A call's signature at the cursor: `label`, with the argument being typed at `activeStart`…`activeEnd` (UTF-16
/// offsets in the label).
public struct CodeSignature: Codable, Sendable, Equatable {
    public var label: String, activeStart: Int?, activeEnd: Int?
    public init(label: String, activeStart: Int? = nil, activeEnd: Int? = nil) {
        self.label = label
        self.activeStart = activeStart
        self.activeEnd = activeEnd
    }
}

/// One completion: what the list shows and what gets inserted.
public struct CodeCompletion: Codable, Sendable, Equatable {
    public var label: String, detail: String?, insert: String
    /// The completion's kind ("method", "keyword"…), its documentation, whether `insert` has tab stops, what it
    /// replaces, and what else it changes.
    public var kind: String?, documentation: String?, snippet: Bool?, edit: CodeEdit?, more: [CodeEdit]?
    public init(
        label: String, detail: String? = nil, insert: String, kind: String? = nil, documentation: String? = nil,
        snippet: Bool? = nil,
        edit: CodeEdit? = nil, more: [CodeEdit]? = nil
    ) {
        self.label = label
        self.detail = detail
        self.insert = insert
        self.kind = kind
        self.documentation = documentation
        self.snippet = snippet
        self.edit = edit
        self.more = more
    }
}

/// A server's edit, which puts `text` from `line`, `column` to `endLine`, `endColumn`, all 0-based and in UTF-16 units.
public struct CodeEdit: Codable, Sendable, Equatable {
    public var line: Int, column: Int, endLine: Int, endColumn: Int, text: String
    public init(line: Int, column: Int, endLine: Int, endColumn: Int, text: String) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.text = text
    }
}

/// One file's part of a server's change, with `edits` as the server gave them.
public struct CodeFileEdit: Codable, Sendable, Equatable {
    public var path: String, edits: [CodeEdit]
    public init(path: String, edits: [CodeEdit]) {
        self.path = path
        self.edits = edits
    }
}

/// A fix or refactoring a server offers at a place, with the edits it makes.
public struct CodeAction: Codable, Sendable, Equatable {
    public var title: String, files: [CodeFileEdit]
    public init(title: String, files: [CodeFileEdit]) {
        self.title = title
        self.files = files
    }
}

/// Why no server runs for a file, which decides what the app asks or offers (trust the project, install the server).
public enum LSPRefusal: Codable, Sendable, Equatable {
    /// A project's language servers run the project's own code (build scripts, Package.swift, its node_modules), so
    /// they don't run before the user trusts the project in Kelp's window (`lsp.trusted`).
    case untrusted
    /// The server command isn't on the login shell's PATH.
    case notInstalled(String)

    public var error: RPCError {
        let message =
            switch self {
            case .untrusted: "This project isn't trusted to run its language servers."
            case .notInstalled(let command): "Language server \(command) isn't installed."
            }
        return RPCError(code: -32002, message: message, data: try? JSONValue.from(self))
    }
    /// Reads the refusal a daemon's error carries, when it is this kind of error.
    public init?(_ error: Error) {
        guard let data = (error as? RPCError)?.data, let refusal = try? data.decode(LSPRefusal.self) else { return nil }
        self = refusal
    }
}

/// Gives a file that a tab shows to one of its servers, starting the server when it isn't running. It fails with an
/// `LSPRefusal` when no server may run there. Each open is matched by an `LSPClose`, and a connection that ends closes
/// what it opened.
public struct LSPOpen: InternalMethod {
    public static let name = "lsp.open"
    public typealias Result = Done
    /// The UI state key that lists the projects the user trusted for language servers and formatters. Only Kelp's
    /// window writes it.
    public static let trustKey = "lsp.trusted"
    public var root: String, path: String, languageId: String, command: String, args: [String]?, text: String
    /// A file with several servers is opened at each one, and `rank` is this server's place among them. The first
    /// server that can answer a question answers it, while problems and fixes come from all of them.
    public var rank: Int?
    /// The server's `initializationOptions`, and its settings, which it gets for `workspace/configuration` by section.
    public var options: JSONValue?, settings: JSONValue?
    public init(
        root: String, path: String, languageId: String, command: String, args: [String]? = nil, text: String,
        rank: Int? = nil, options: JSONValue? = nil, settings: JSONValue? = nil
    ) {
        self.root = root
        self.path = path
        self.languageId = languageId
        self.command = command
        self.args = args
        self.text = text
        self.rank = rank
        self.options = options
        self.settings = settings
    }
}
/// A language server command on this Mac: whether it is installed, and, for the project asked about, whether it runs
/// (or is starting), how many open files it has, and whether it failed to start or died.
public struct LSPServerState: Codable, Sendable, Equatable {
    public var command: String, installed: Bool, running: Bool, files: Int, failed: Bool
    public init(command: String, installed: Bool, running: Bool = false, files: Int = 0, failed: Bool = false) {
        self.command = command
        self.installed = installed
        self.running = running
        self.files = files
        self.failed = failed
    }
}
/// Returns what is known about each of `commands`, named as the languages name them, for Settings › Languages and a
/// file's own list. `root` is the project whose servers count as running. With nil, every project's servers count.
public struct LSPServers: InternalMethod {
    public static let name = "lsp.servers"
    public typealias Result = [LSPServerState]
    public var root: String?, commands: [String]
    public init(root: String? = nil, commands: [String]) {
        self.root = root
        self.commands = commands
    }
}
/// Stops the project's servers of `command` and starts them again with the files that were open at them, as last
/// sent.
public struct LSPRestart: InternalMethod {
    public static let name = "lsp.restart"
    public typealias Result = Done
    public var root: String, command: String
    public init(root: String, command: String) {
        self.root = root
        self.command = command
    }
}
/// Sends the file's whole text as it is now, as a notification while typing.
public struct LSPChange: InternalMethod {
    public static let name = "lsp.change"
    public typealias Result = Done
    public var root: String, path: String, text: String
    public init(root: String, path: String, text: String) {
        self.root = root
        self.path = path
        self.text = text
    }
}
/// Tells the server that a tab showing the file closed.
public struct LSPClose: InternalMethod {
    public static let name = "lsp.close"
    public typealias Result = Done
    public var root: String, path: String
    public init(root: String, path: String) {
        self.root = root
        self.path = path
    }
}
/// Returns where the symbol at a position is defined. Positions are 1-based lines and columns.
public struct LSPDefinition: InternalMethod {
    public static let name = "lsp.definition"
    public typealias Result = CodeLocation?
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
    }
}
/// Returns the completions at a 1-based position.
public struct LSPCompletion: InternalMethod {
    public static let name = "lsp.completion"
    public typealias Result = [CodeCompletion]
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
    }
}
/// Returns the innermost function, method, class or module around a line (the `${symbol}` of Test at Cursor).
public struct LSPSymbol: InternalMethod {
    public static let name = "lsp.symbol"
    public typealias Result = String?
    public var root: String, path: String, line: Int
    public init(root: String, path: String, line: Int) {
        self.root = root
        self.path = path
        self.line = line
    }
}

/// Returns what the language server last said is wrong with the file at `path`. Problems also reach a tab with its
/// `FileEvent`.
public struct LSPProblems: InternalMethod {
    public static let name = "lsp.problems"
    public typealias Result = [CodeProblem]
    public var path: String
    public init(path: String) { self.path = path }
}

/// Returns the names the file at `path` defines, as its language server lists them, from top to bottom.
public struct LSPSymbols: InternalMethod {
    public static let name = "lsp.symbols"
    public typealias Result = [CodeSymbol]
    public var root: String, path: String
    public init(root: String, path: String) {
        self.root = root
        self.path = path
    }
}

/// Returns the names matching `query` in every file of the project, as the server of the file at `path` knows them
/// from its index.
public struct LSPWorkspaceSymbols: InternalMethod {
    public static let name = "lsp.workspaceSymbols"
    public typealias Result = [CodeSymbol]
    public var root: String, path: String, query: String
    public init(root: String, path: String, query: String) {
        self.root = root
        self.path = path
        self.query = query
    }
}

/// Returns what the server says about the symbol at a 1-based position: its signature and documentation, as
/// Markdown.
public struct LSPHover: InternalMethod {
    public static let name = "lsp.hover"
    public typealias Result = String?
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Returns the signature of the call around a 1-based position.
public struct LSPSignature: InternalMethod {
    public static let name = "lsp.signature"
    public typealias Result = CodeSignature?
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Returns where the symbol at a 1-based position is used in files under `root`. Each use has its line's text, and
/// `path` is relative to `root`.
public struct LSPReferences: InternalMethod {
    public static let name = "lsp.references"
    public typealias Result = [SearchMatch]
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Returns what renaming the symbol at a 1-based position to `name` changes. Nothing is written, because the app
/// applies the edits.
public struct LSPRename: InternalMethod {
    public static let name = "lsp.rename"
    public typealias Result = [CodeFileEdit]
    public var root: String, path: String, line: Int, column: Int, name: String
    public init(root: String, path: String, line: Int, column: Int, name: String) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
        self.name = name
    }
}

/// Returns the fixes and refactorings a server offers at a 1-based line and column, keeping only those whose edits the
/// server can give.
public struct LSPActions: InternalMethod {
    public static let name = "lsp.actions"
    public typealias Result = [CodeAction]
    public var root: String, path: String, line: Int, column: Int
    public init(root: String, path: String, line: Int, column: Int) {
        self.root = root
        self.path = path
        self.line = line
        self.column = column
    }
}
