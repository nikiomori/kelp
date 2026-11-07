import Core
import Foundation
import GitKit
import os

/// Add Project's other two ways in: clone by URL (progress as `event.clone`; a half-made folder is removed when it fails
/// or is cancelled) and a new empty project (`git init`, like the scratch project).
extension Forges {
    /// `parent/name`, checked: a real folder to go in, a plain name, nothing there yet.
    static func newFolder(_ name: String, in parent: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw RPCError.invalidParams("Enter a name for the project folder.")
        }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &dir), dir.boolValue else {
            throw RPCError.invalidParams("Choose the folder it goes in.")
        }
        let dest = (parent as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest) else {
            throw RPCError.invalidParams(
                "“\(name)” already exists in \((parent as NSString).abbreviatingWithTildeInPath).")
        }
        return dest
    }

    func clone(_ url: String, into parent: String, folder: String? = nil, id: String, conn: Int) async throws -> String
    {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.hasPrefix("-") else { throw RPCError.invalidParams("Enter the repository's URL.") }
        // Holds a slot, so an update waits for it (`Daemon.upgrade`).
        guard await offloads.acquire() else { throw RPCError.invalidParams("Kelp is updating. Try again in a moment.") }
        defer { offloads.release() }
        let dest = try Self.newFolder(folder ?? RepoClone.folderName(url), in: parent)
        // Made here, atomically: two clones that pick the same name can't both get past this, so the cleanup below only
        // ever removes this clone's own folder (git clones into an empty folder that exists).
        guard Workspaces.claim(dest) else {
            throw RPCError.invalidParams(
                "“\((dest as NSString).lastPathComponent)” already exists in \((parent as NSString).abbreviatingWithTildeInPath)."
            )
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["clone", "--progress", "--", url, dest]
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        proc.environment = env
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        // git rewrites its progress line with \r: pass the latest one on, at most a few times a second.
        let log = CloneLog(), eof = DispatchSemaphore(value: 0)
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // Not `availableData`, which raises on a read error and would take the daemon down.
            let data =
                (Log.store.attempt("reading git's progress") { try handle.read(upToCount: 65536) } ?? nil) ?? Data()
            // The end: the handler goes (it would be called again and again with nothing), and the failure can be read.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                eof.signal()
                return
            }
            guard let line = log.add(data) else { return }
            self?.notify(CloneEvent(id: id, line: line), to: [conn])
        }
        clones.set(id, proc)
        let status: (Int32, Process.TerminationReason) = try await withCheckedThrowingContinuation { continuation in
            proc.terminationHandler = { continuation.resume(returning: ($0.terminationStatus, $0.terminationReason)) }
            do { try proc.run() } catch {
                proc.terminationHandler = nil
                // Claimed above, nothing written: a retry finds the name free.
                Log.store.attempt("removing an unstarted clone's folder") {
                    try FileManager.default.removeItem(atPath: dest)
                }
                continuation.resume(throwing: error)
            }
        }
        clones.set(id, nil)
        // git's last words ("fatal: …") can still be on their way when it has exited; a child holding the pipe can't
        // keep this waiting past 2 s.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = eof.wait(timeout: .now() + 2)
                continuation.resume()
            }
        }
        err.fileHandleForReading.readabilityHandler = nil
        guard status.0 == 0 else {
            // This clone made it (mkdir above), nobody else wrote there.
            Log.store.attempt("removing a failed clone's folder") { try FileManager.default.removeItem(atPath: dest) }
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
    func add(_ data: Data) -> String? {
        state.withLock { st in
            st.text += String(bytes: data, encoding: .utf8) ?? ""   // git writes ASCII here
            if st.text.count > 8000 { st.text = String(st.text.suffix(4000)) }
            guard Date().timeIntervalSince(st.sent) > 0.2 else { return nil }
            let lines = st.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            guard let last = lines.last.map(String.init), !last.isEmpty else { return nil }
            st.sent = Date()
            return last.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "fatal: repository 'x' not found" → "Repository 'x' not found".
    var failure: String? {
        let lines = state.withLock { $0 }.text.split(whereSeparator: \.isNewline).map(String.init)
        guard
            let line = lines.last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("ERROR:") })
                ?? lines.last
        else { return nil }
        var message = line.replacingOccurrences(of: #"^(fatal|error|ERROR): ?"#, with: "", options: .regularExpression)
        message = message.prefix(1).uppercased() + message.dropFirst()
        return message
    }
}

extension RepoClone: AsyncHandled {
    func handle(_ work: ForgeWork) async throws -> Repo { try await handle(work, conn: -1) }
    func handle(_ work: ForgeWork, conn: Int) async throws -> Repo {
        let dest = try await work.forges.clone(
            url, into: parent, folder: folder, id: id ?? UUID().uuidString, conn: conn)
        return try await work.forges.offloads.run { try RepoAdd(path: dest).handle(work.workspaces) }   // runs git: off the cooperative pool
    }
}
extension RepoCloneCancel: AsyncHandled {
    func handle(_ forges: Forges) async throws -> Done {
        forges.clones.cancel(id)
        return Done()
    }
}
