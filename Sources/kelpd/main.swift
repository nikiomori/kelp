import Core
import Daemon
import Foundation

// kelpd is Kelp's background daemon. launchd runs it (see `kelp install`), or the app or CLI starts it on demand.
if CommandLine.arguments.contains("--can-adopt") {
    let answer = Handover.canAdopt(root: Paths.root)
    if answer.ok { print(answer.said) } else { FileHandle.standardError.write(Data((answer.said + "\n").utf8)) }
    exit(answer.ok ? 0 : 1)
}   // an update runs the new kelpd with --can-adopt before it execs that kelpd
// kelpd makes a process session of its own when it can. The processes it starts outside terminals then stay in that
// session, which is how `Callers.session(running:)` tells they are kelpd's. A process-group leader can't make one, and
// launchd and the app's Process both start kelpd as one. Then such a leftover process counts as `detached`, and it is
// held to an agent's rules all the same (`Daemon.strict`).
if getsid(0) != getpid(), setsid() < 0 {
    FileHandle.standardError.write(
        Data("kelpd: no process session of its own (\(errno)); leftovers count as detached\n".utf8))
}
// launchd gives 256 file descriptors, but every agent holds 3, every open terminal 2 more and every git or gh run 2.
// So kelpd raises its limit as far as it is allowed, up to OPEN_MAX.
var files = rlimit()
if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < rlim_t(OPEN_MAX) {
    files.rlim_cur = min(files.rlim_max, rlim_t(OPEN_MAX))
    setrlimit(RLIMIT_NOFILE, &files)
}
nonisolated(unsafe) var sources: [DispatchSourceProtocol] = []   // must outlive this scope or the handlers vanish
do {
    // After an update execs kelpd in place (`daemon.upgrade`), this takes what the previous kelpd handed over and
    // reaps the other processes that kelpd ran.
    let handover = CommandLine.arguments.firstIndex(of: "--adopt").flatMap { index in
        CommandLine.arguments.dropFirst(index + 1).first
    }.flatMap(Handover.take)
    handover?.reapOthers()
    if let stable = Paths.seed { HomeSeed.fill(Paths.root, from: stable) }
    let daemon = try Daemon(root: Paths.root)
    daemon.strict()
    try daemon.start(adopting: handover)
    let quit = { @Sendable in
        daemon.stop()
        exit(0)
    }
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        src.setEventHandler(handler: quit)
        src.resume()
        sources.append(src)
    }
    // kelpd quits when its home folder is deleted or moved away (a temp folder for a test or a snapshot). Nobody can
    // reach its socket then, and an idle daemon has no other reason to end, so it used to stay for good (once 90 of
    // them, 600 MB).
    let home = open(Paths.root.path, O_EVTONLY)
    if home >= 0 {
        let gone = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: home, eventMask: [.delete, .rename], queue: .main)
        gone.setEventHandler(handler: quit)
        gone.resume()
        sources.append(gone)
    }
    // When a test process started kelpd (KELP_TEST_PID, set by the tests' isolation), kelpd ends when that test does.
    if let pid = ProcessInfo.processInfo.environment["KELP_TEST_PID"].flatMap(Int32.init) {
        let ended = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        ended.setEventHandler(handler: quit)
        ended.resume()
        sources.append(ended)
        if kill(pid, 0) != 0, errno == ESRCH { quit() }   // the test process ended before the watch began
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("kelpd: \(Daemon.startFailed(error, root: Paths.root))\n".utf8))
    exit(1)
}
