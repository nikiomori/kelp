import Core
import Foundation

// What the editor asks a server about a place in a file: definition, completion, references, rename, hover, signature, symbols.

extension LSPClient {
    public func definition(_ path: String, line: Int, column: Int) async throws -> CodeLocation? {
        let result = try await request("textDocument/definition", at(path, line, column))
        guard let location = result.array?.first ?? (result == .null ? nil : result) else { return nil }
        let uri = location["uri"]?.string ?? location["targetUri"]?.string
        let range = location["range"] ?? location["targetSelectionRange"]
        guard let uri, let target = URL(string: uri)?.path else { return nil }
        return CodeLocation(
            path: target, line: (range?["start"]?["line"]?.int ?? 0) + 1,
            column: (range?["start"]?["character"]?.int ?? 0) + 1)
    }

    public func completion(_ path: String, line: Int, column: Int) async throws -> [CodeCompletion] {
        Self.completions(try await request("textDocument/completion", at(path, line, column)))
    }

    private static let completionKinds = [
        2: "method", 3: "function", 4: "constructor", 5: "field", 6: "variable", 7: "class", 8: "interface",
        9: "module", 10: "property", 12: "value",
        13: "enum", 14: "keyword", 15: "snippet", 17: "file", 19: "folder", 20: "enum", 21: "constant", 22: "struct"
    ]

    static func completions(_ result: JSONValue) -> [CodeCompletion] {
        func edit(_ textEdit: JSONValue, text: String? = nil) -> CodeEdit? {
            guard let span = span(textEdit["range"] ?? textEdit["replace"]),
                let newText = text ?? textEdit["newText"]?.string
            else { return nil }
            return CodeEdit(
                line: span.line, column: span.column, endLine: span.endLine, endColumn: span.endColumn, text: newText)
        }
        let items = (result.array ?? result["items"]?.array ?? []).sorted {
            ($0["sortText"]?.string ?? "") < ($1["sortText"]?.string ?? "")
        }
        return items.prefix(200).map { item in
            let more = (item["additionalTextEdits"]?.array ?? []).compactMap { edit($0) }
            let doc = item["documentation"]
            return CodeCompletion(
                label: item["label"]?.string ?? "", detail: item["detail"]?.string,
                insert: item["textEdit"]?["newText"]?.string ?? item["insertText"]?.string
                    ?? item["label"]?.string ?? "",
                kind: completionKinds[item["kind"]?.int ?? 0], documentation: doc?.string ?? doc?["value"]?.string,
                snippet: item["insertTextFormat"]?.int == 2 ? true : nil,
                edit: item["textEdit"].flatMap { edit($0) },
                more: more.isEmpty ? nil : more)
        }
    }

    /// The innermost function, method, class or module around a 1-based line (the test at the cursor).
    public func symbol(_ path: String, line: Int) async throws -> String? {
        Self.enclosingSymbol(
            try await request("textDocument/documentSymbol", .obj(["textDocument": .obj(["uri": Self.uri(path)])])),
            line: line)
    }

    /// From either shape of a documentSymbol result: nested `DocumentSymbol`s or flat `SymbolInformation`s. The smallest
    /// range wins; on a tie the later one (a child is visited after its parent).
    public func references(_ path: String, line: Int, column: Int) async throws -> [CodeLocation] {
        var params = at(path, line, column)
        if case .object(var object) = params {
            object["context"] = .obj(["includeDeclaration": true])
            params = .object(object)
        }
        return (try await request("textDocument/references", params).array ?? []).compactMap { location in
            guard let file = location["uri"]?.string.flatMap({ URL(string: $0)?.path }),
                let start = location["range"]?["start"]
            else {
                return nil
            }
            return CodeLocation(
                path: file, line: (start["line"]?.int ?? 0) + 1, column: (start["character"]?.int ?? 0) + 1)
        }
    }

    public func rename(_ path: String, line: Int, column: Int, to name: String) async throws -> [CodeFileEdit] {
        var params = at(path, line, column)
        if case .object(var object) = params {
            object["newName"] = .string(name)
            params = .object(object)
        }
        return Self.fileEdits(try await request("textDocument/rename", params))
    }

    /// A WorkspaceEdit, in either of its shapes.
    static func fileEdits(_ edit: JSONValue) -> [CodeFileEdit] {
        func edits(_ list: JSONValue?) -> [CodeEdit] {
            (list?.array ?? []).compactMap { textEdit in
                guard let span = span(textEdit["range"]), let text = textEdit["newText"]?.string else { return nil }
                return CodeEdit(
                    line: span.line, column: span.column, endLine: span.endLine, endColumn: span.endColumn, text: text)
            }
        }
        var out: [CodeFileEdit] = []
        for change in edit["documentChanges"]?.array ?? [] {
            if let path = change["textDocument"]?["uri"]?.string.flatMap({ URL(string: $0)?.path }) {
                out.append(CodeFileEdit(path: path, edits: edits(change["edits"])))
            }
        }
        if case .object(let changes)? = edit["changes"] {
            for (uri, list) in changes.sorted(by: { $0.key < $1.key }) {
                if let path = URL(string: uri)?.path { out.append(CodeFileEdit(path: path, edits: edits(list))) }
            }
        }
        return out.filter { !$0.edits.isEmpty }
    }

    public func hover(_ path: String, line: Int, column: Int) async throws -> String? {
        Self.hoverText(try await request("textDocument/hover", at(path, line, column)))
    }

    public func signature(_ path: String, line: Int, column: Int) async throws -> CodeSignature? {
        Self.signature(try await request("textDocument/signatureHelp", at(path, line, column)))
    }

    /// `contents` comes in all three of the protocol's shapes: a MarkupContent, a MarkedString, a list of them.
    static func hoverText(_ result: JSONValue) -> String? {
        func text(_ content: JSONValue) -> String? {
            if let plain = content.string { return plain }
            guard let value = content["value"]?.string else { return nil }
            return content["language"]?.string.map { "```\($0)\n\(value)\n```" } ?? value
        }
        guard let contents = result["contents"] else { return nil }
        let joined = (contents.array?.compactMap(text).joined(separator: "\n\n") ?? text(contents))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined?.isEmpty == false ? joined : nil
    }

    /// A parameter's label is its text, or its offsets in the signature's.
    static func signature(_ result: JSONValue) -> CodeSignature? {
        let all = result["signatures"]?.array ?? []
        guard !all.isEmpty else { return nil }
        let active = all[min(result["activeSignature"]?.int ?? 0, all.count - 1)]
        guard let label = active["label"]?.string else { return nil }
        let params = active["parameters"]?.array ?? []
        let index = active["activeParameter"]?.int ?? result["activeParameter"]?.int ?? 0
        guard params.indices.contains(index), let param = params[index]["label"] else {
            return CodeSignature(label: label)
        }
        if let name = param.string, let range = label.range(of: name) {
            let start = label.utf16.distance(from: label.startIndex, to: range.lowerBound)
            return CodeSignature(label: label, activeStart: start, activeEnd: start + name.utf16.count)
        }
        return CodeSignature(label: label, activeStart: param.array?.first?.int, activeEnd: param.array?.last?.int)
    }

    /// The file's symbols, nested ones in with the rest, top to bottom.
    public func symbols(_ path: String) async throws -> [CodeSymbol] {
        Self.symbols(
            try await request("textDocument/documentSymbol", .obj(["textDocument": .obj(["uri": Self.uri(path)])])))
    }

    private static let symbolKinds = [
        2: "module", 3: "namespace", 5: "class", 6: "method", 7: "property", 8: "field", 9: "initializer", 10: "enum",
        11: "interface", 12: "function", 13: "variable", 14: "constant", 22: "case", 23: "struct"
    ]

    /// The project's names matching `query`, as the server's index has them.
    public func workspaceSymbols(_ query: String) async throws -> [CodeSymbol] {
        Self.workspaceSymbols(try await request("workspace/symbol", .obj(["query": .string(query)])))
    }

    /// SymbolInformation or WorkspaceSymbol (which may leave the range out: the file's top).
    static func workspaceSymbols(_ result: JSONValue) -> [CodeSymbol] {
        (result.array ?? []).compactMap { symbol in
            let path = symbol["location"]?["uri"]?.string.flatMap { URL(string: $0)?.path }
            guard let name = symbol["name"]?.string, let path else { return nil }
            let line = (symbol["location"]?["range"]?["start"]?["line"]?.int ?? 0) + 1
            return CodeSymbol(
                name: name, kind: symbolKinds[symbol["kind"]?.int ?? 0] ?? "symbol", line: line, path: path)
        }
    }

    static func symbols(_ result: JSONValue) -> [CodeSymbol] {
        var out: [CodeSymbol] = []
        func visit(_ node: JSONValue) {
            let range = node["selectionRange"] ?? node["range"] ?? node["location"]?["range"]
            if let name = node["name"]?.string, let line = range?["start"]?["line"]?.int {
                out.append(
                    CodeSymbol(name: name, kind: symbolKinds[node["kind"]?.int ?? 0] ?? "symbol", line: line + 1))
            }
            node["children"]?.array?.forEach(visit)
        }
        result.array?.forEach(visit)
        return out.sorted { $0.line < $1.line }
    }

    static func enclosingSymbol(_ result: JSONValue, line: Int) -> String? {
        var best: (name: String, span: Int)?
        func visit(_ node: JSONValue) {
            let range = node["range"] ?? node["location"]?["range"]
            if let name = node["name"]?.string, [2, 3, 5, 6, 12, 23].contains(node["kind"]?.int ?? 0),   // module, namespace, class, method, function, struct
                let start = range?["start"]?["line"]?.int, let end = range?["end"]?["line"]?.int, start < line,
                line - 1 <= end, end - start <= best?.span ?? .max
            {
                best = (name, end - start)
            }
            node["children"]?.array?.forEach(visit)
        }
        result.array?.forEach(visit)
        return best?.name
    }
}
