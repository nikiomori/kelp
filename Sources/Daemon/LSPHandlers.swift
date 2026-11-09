import Core
import Foundation
import LSPKit

// lsp.*: the RPCs, each answered by LSPHost, and which projects the user trusted for language servers.

extension LSPHost {
    /// The user trusted `root` for language servers and formatters in Kelp's window (`state.set` of `lsp.trusted`, which
    /// only the window may write).
    func trusted(_ root: String) -> Bool {
        let state = store.look("what's trusted") { try $0.uiState(prefix: LSPOpen.trustKey) }
        return (state?[LSPOpen.trustKey]?.array ?? []).contains(.string(root))
    }
}

extension Methods {
    static let lspMethods: [any Handled.Type] = [LSPOpen.self, LSPChange.self, LSPClose.self, LSPProblems.self]
    static let lspAsyncMethods: [any AsyncHandled.Type] = [
        LSPDefinition.self, LSPCompletion.self, LSPSymbol.self, LSPSymbols.self, LSPHover.self, LSPSignature.self,
        LSPReferences.self, LSPRename.self, LSPActions.self, LSPWorkspaceSymbols.self
    ]
}

extension LSPOpen: Handled {
    /// Before the changes typed after it. Quick: a server starts on a task of its own.
    static var inOrder: Bool { true }
    func handle(_ lsp: LSPHost, conn: Int) throws -> Done {
        guard lsp.remotes.of(root) == nil else {
            throw RPCError.invalidParams("No language servers for a project on another machine.")
        }
        // A project's language servers run its own code: the daemon checks, whoever asks.
        guard lsp.trusted(root) else { throw LSPRefusal.untrusted.error }
        // Not waiting for the login shell's PATH on this thread (seconds, right after the daemon starts): until it's read,
        // a server that isn't installed fails when it starts, off this thread, and the tab just gets no server.
        do { _ = try LoginPath.resolveNow(command) } catch { throw LSPRefusal.notInstalled(command).error }
        lsp.open(conn: conn, self)
        return Done()
    }
}

extension LSPChange: Handled {
    static var inOrder: Bool { true }   // keystrokes' text, in the order typed
    func handle(_ lsp: LSPHost) throws -> Done {
        lsp.change(root, path, text: text)
        return Done()
    }
}

extension LSPClose: Handled {
    static var inOrder: Bool { true }
    func handle(_ lsp: LSPHost, conn: Int) throws -> Done {
        lsp.close(conn: conn, root, path)
        return Done()
    }
}

extension LSPProblems: Handled {
    func handle(_ lsp: LSPHost) throws -> [CodeProblem] { lsp.problems(path) }
}

extension LSPDefinition: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> CodeLocation? {
        guard let client = await lsp.client(root, path) else { return nil }
        return try await client.definition(path, line: line, column: column)
    }
}

extension LSPCompletion: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [CodeCompletion] {
        guard let client = await lsp.client(root, path) else { return [] }
        return try await client.completion(path, line: line, column: column)
    }
}

extension LSPSymbol: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> String? {
        guard let client = await lsp.client(root, path) else { return nil }
        return try await client.symbol(path, line: line)
    }
}

extension LSPSymbols: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [CodeSymbol] {
        guard let client = await lsp.client(root, path) else { return [] }
        return try await client.symbols(path)
    }
}

extension LSPWorkspaceSymbols: AsyncHandled {
    /// The project's own: a toolchain's or a dependency's names aren't what's looked for.
    func handle(_ lsp: LSPHost) async throws -> [CodeSymbol] {
        guard let client = await lsp.client(root, path) else { return [] }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        return try await client.workspaceSymbols(query).compactMap { symbol in
            guard let symbolPath = symbol.path,
                case let real = URL(fileURLWithPath: symbolPath).resolvingSymlinksInPath().path,
                real.hasPrefix(base)
            else { return nil }
            return CodeSymbol(
                name: symbol.name, kind: symbol.kind, line: symbol.line, path: root + "/" + real.dropFirst(base.count))
        }
    }
}

extension LSPHover: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> String? {
        guard let client = await lsp.client(root, path) else { return nil }
        return try await client.hover(path, line: line, column: column)
    }
}

extension LSPSignature: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> CodeSignature? {
        guard let client = await lsp.client(root, path) else { return nil }
        return try await client.signature(path, line: line, column: column)
    }
}

extension LSPReferences: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [SearchMatch] {
        guard let client = await lsp.client(root, path) else { return [] }
        let found = try await client.references(path, line: line, column: column), root = root
        return try await lsp.offloads.run { Self.lines(of: found, in: root) }
    }

    /// Each place with its line's text, read from disk, for the project's files.
    private static func lines(of found: [CodeLocation], in root: String) -> [SearchMatch] {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        var texts: [String: [Substring]] = [:]
        return found.compactMap { location in
            let real = URL(fileURLWithPath: location.path).resolvingSymlinksInPath().path
            guard real.hasPrefix(base) else { return nil }   // the toolchain's own files: the panel lists the project's
            if texts[real] == nil {
                let text = Log.session.attempt("reading \(real)") { try String(contentsOfFile: real, encoding: .utf8) }
                texts[real] = text?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
            }
            let text =
                texts[real].flatMap { $0.indices.contains(location.line - 1) ? String($0[location.line - 1]) : nil }
                ?? ""
            return SearchMatch(
                path: String(real.dropFirst(base.count)), line: location.line,
                text: text.trimmingCharacters(in: .whitespaces))
        }
    }
}

extension LSPRename: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [CodeFileEdit] {
        guard let client = await lsp.client(root, path) else { return [] }
        return try await client.rename(path, line: line, column: column, to: name)
    }
}

extension LSPActions: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [CodeAction] {
        guard let client = await lsp.client(root, path) else { return [] }
        return try await client.actions(path, line: line, column: column)
    }
}
