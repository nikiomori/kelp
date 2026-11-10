import Core
import Foundation

// process.*: the login shell's PATH and lookups, and a command an extension runs.

extension ProcessRefreshPath: Handled {
    func handle(_: NoService) throws -> Done {
        LoginPath.reread()
        return Done()
    }   // runs the user's shell: not `quick`, on an offload thread
}

extension ProcessWhich: Handled {
    func handle(_: NoService) throws -> Result {
        Dictionary(commands.compactMap { c in LoginPath.find(c).map { (c, $0) } }) { a, _ in a }
    }
}

extension ProcessRun: Handled {
    func handle(_ setup: SessionSetup) throws -> Result {
        guard argv.first?.isEmpty == false else { throw RPCError.invalidParams("Nothing to run.") }
        if let extensionId { try setup.requireEnabledExtension(extensionId) }
        // What sessions get (PATH with `kelp` on it, this home), minus the markers of whatever started the daemon.
        var env = ProcessInfo.processInfo.environment.filter { k, _ in !PTY.scrubbed.contains { k.hasPrefix($0) } }
        env["PATH"] = Sessions.childPath
        env["KELP_HOME"] = setup.root.path
        env["KELP_SOCKET"] = setup.socketPath
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        let result = try Subprocess.run(
            argv, cwd: dir, env: env, stdin: stdin.map { Data($0.utf8) },
            timeLimit: max(0.1, min(timeLimit ?? 60, 86400)),
            limit: Self.outputLimit)
        // Not a part as if it were all of it: a formatter's would replace the file's text.
        guard !result.truncated else {
            let name = ((argv.first ?? "") as NSString).lastPathComponent
            throw RPCError.internalError(
                "\(name) printed more than \(Self.outputLimit >> 20) MB, more than Kelp reads.")
        }
        // Lossy on purpose: a tool's output with a stray byte should still show.
        return Result(
            code: result.status, stdout: String(decoding: result.stdout, as: UTF8.self),
            stderr: String(decoding: result.stderr, as: UTF8.self),
            timedOut: result.timedOut)
    }

    /// Of each stream: the reply carries both, JSON-escaped (a control byte takes six), under a connection's `backlogLimit`.
    static let outputLimit = 16 << 20
}

extension SessionSetup {
    /// An extension's command runs only while that extension is installed and on (Settings › Extensions): a page or a
    /// list left open after turning it off can't run it any more. `id` is its folder's name; the manifest has its id.
    func requireEnabledExtension(_ id: String) throws {
        struct Manifest: Decodable {
            var id: String
            var name: String?
        }
        // Paths.extensions of this home
        let file = root.appendingPathComponent("extensions").appendingPathComponent(id).appendingPathComponent(
            "extension.json")
        guard !id.isEmpty, (id as NSString).lastPathComponent == id, id != "..", id != ".",
            let data = FileManager.default.contents(atPath: file.path),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw RPCError.invalidParams("No extension \"\(id)\".") }
        // Limit: unset means none of the user's extensions is off (the app's default-off list names built-ins only).
        let off = Set(settings[SettingKeys.disabledExtensions] ?? [])
        let name = manifest.name ?? manifest.id
        guard !off.contains(manifest.id) else {
            throw RPCError.invalidParams("The extension “\(name)” is turned off.")
        }
        guard trustsExtension(id) else {
            throw RPCError.invalidParams(
                "The extension “\(name)” waits to be allowed as it is now: in Settings › Extensions."
            )
        }
    }

    /// Whether the user allowed the extension in folder `name` to run commands as its files are now (`IDE.extensionTrustKey`,
    /// which only Kelp's window writes). Without a record, none is: the window records what was installed before it asked
    /// (`ExtensionTrust.adopt`) and asks about the rest. `read`: the folder's files as just read, whose manifest the caller
    /// runs from (`IDE.extensionFiles`), so what was checked is what runs.
    func trustsExtension(_ name: String, read: [String: Data]? = nil) -> Bool {
        guard
            let state = Log.store.attempt(
                "reading the allowed extensions", { try store.uiState(prefix: IDE.extensionTrustKey) })
        else { return false }
        let now =
            read.map { IDE.extensionDigest($0) }
            ?? IDE.extensionDigest(root.appendingPathComponent("extensions").appendingPathComponent(name))
        return state[IDE.extensionTrustKey]?[name]?.string == now
    }
}
