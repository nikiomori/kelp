import Foundation
import os
import Core
import GitKit

/// Add Project's other two ways in: clone by URL (progress as `event.clone`; a half-made folder is removed when it fails
/// or is cancelled) and a new empty project (`git init`, like the scratch project).
extension Forges {
    /// `parent/name`, checked: a real folder to go in, a plain name, nothing there yet.
    static func newFolder(_ name: String, in parent: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw RPCError.invalidParams("Enter a name for the project folder.") }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &dir), dir.boolValue else { throw RPCError.invalidParams("Choose the folder it goes in.") }
        let dest = (parent as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest) else {
            throw RPCError.invalidParams("“\(name)” already exists in \((parent as NSString).abbreviatingWithTildeInPath).")
        }
        return dest
    }

    func clone(_ url: String, into parent: String, folder: String? = nil, id: String, conn: Int) async throws -> String {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.hasPrefix("-") else { throw RPCError.invalidParams("Enter the repository's URL.") }
        let dest = try Self.newFolder(folder ?? RepoClone.folderName(url), in: parent)
        // Made here, atomically: two clones that pick the same name can't both get past this, so the cleanup below only
        // ever removes this clone's own folder (git clones into an empty folder that exists).
        guard Workspaces.claim(dest) else {
            throw RPCError.invalidParams("“\((dest as NSString).lastPathComponent)” already exists in \((parent as NSString).abbreviatingWithTildeInPath).")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["clone", "--progress", "--", url, dest]
        var env = ProcessInfo.processInfo.environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        proc.environment = env
        let err = Pipe(); proc.standardError = err; proc.standardOutput = FileHandle.nullDevice; proc.standardInput = FileHandle.nullDevice
        // git rewrites its progress line with \r: pass the latest one on, at most a few times a second.
        let log = CloneLog()
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let line = log.add(h.availableData) else { return }
            self?.notify(CloneEvent(id: id, line: line), to: [conn])
        }
        clones.set(id, proc)
        let status: (Int32, Process.TerminationReason) = try await withCheckedThrowingContinuation { c in
            proc.terminationHandler = { c.resume(returning: ($0.terminationStatus, $0.terminationReason)) }
            do { try proc.run() } catch {
                proc.terminationHandler = nil
                try? FileManager.default.removeItem(atPath: dest)   // claimed above, nothing written: a retry finds the name free
                c.resume(throwing: error)
            }
        }
        clones.set(id, nil)
        err.fileHandleForReading.readabilityHandler = nil
        guard status.0 == 0 else {
            try? FileManager.default.removeItem(atPath: dest)   // this clone made it (mkdir above), nobody else wrote there
            if status.1 == .uncaughtSignal || status.0 == 130 { throw RPCError.invalidParams("Clone cancelled.") }
            throw RPCError.invalidParams(log.failure ?? "git clone failed (exit code \(status.0)).")
        }
        return dest
    }
}

/// git's stderr during a clone: the last progress line, and what it said when it failed.
final class CloneLog: Sendable {
    private let state = OSAllocatedUnfairLock<(text: String, sent: Date)>(initialState: ("", .distantPast))

    /// The newest complete line, when it's time to show one.
    func add(_ d: Data) -> String? {
        state.withLock { st in
            st.text += String(bytes: d, encoding: .utf8) ?? ""   // git writes ASCII here
            if st.text.count > 8000 { st.text = String(st.text.suffix(4000)) }
            guard Date().timeIntervalSince(st.sent) > 0.2 else { return nil }
            let lines = st.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            guard let last = lines.last.map(String.init), !last.isEmpty else { return nil }
            st.sent = Date(); return last.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "fatal: repository 'x' not found" → "Repository 'x' not found".
    var failure: String? {
        let lines = state.withLock { $0 }.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
        guard let f = lines.last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("ERROR:") }) ?? lines.last else { return nil }
        var m = f.replacingOccurrences(of: #"^(fatal|error|ERROR): ?"#, with: "", options: .regularExpression)
        m = m.prefix(1).uppercased() + m.dropFirst()
        return m
    }
}

extension RepoClone: AsyncHandled {
    func handle(_ work: ForgeWork) async throws -> Repo { try await handle(work, conn: -1) }
    func handle(_ work: ForgeWork, conn: Int) async throws -> Repo {
        let dest = try await work.forges.clone(url, into: parent, folder: folder, id: id ?? UUID().uuidString, conn: conn)
        return try await work.forges.offloads.run { try RepoAdd(path: dest).handle(work.workspaces) }   // runs git: off the cooperative pool
    }
}
extension RepoCloneCancel: AsyncHandled { func handle(_ forges: Forges) async throws -> Done { forges.clones.cancel(id); return Done() } }
