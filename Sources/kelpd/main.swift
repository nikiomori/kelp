import Foundation
import Core
import Daemon

// kelpd: background daemon. Run by launchd (see `kelp install`) or started on demand by the app/CLI.
if CommandLine.arguments.contains("--can-adopt") { print(Handover.canAdopt); exit(0) }   // asked before an update execs this
signal(SIGPIPE, SIG_IGN)
// Its own process session where it can have one: what it starts that isn't a terminal's stays in it, and is told for
// kelpd's by that (`Sessions.session(running:)`). A process-group leader can't (launchd starts it as one, and the app's
// Process too): then such a leftover is `detached`, held to an agent's rules all the same (`Daemon.strict`).
if getsid(0) != getpid(), setsid() < 0 {
    FileHandle.standardError.write(Data("kelpd: no process session of its own (\(errno)); leftovers count as detached\n".utf8))
}
// launchd gives 256 fds; every agent holds 3, every open terminal 2 more, every git or gh run 2: take what's allowed.
var files = rlimit()
if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < rlim_t(OPEN_MAX) {
    files.rlim_cur = min(files.rlim_max, rlim_t(OPEN_MAX)); setrlimit(RLIMIT_NOFILE, &files)
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []   // must outlive this scope or the handlers vanish
nonisolated(unsafe) var homeWatch: DispatchSourceFileSystemObject?   // the same
nonisolated(unsafe) var testWatch: DispatchSourceProcess?   // the same
do {
    // An update's exec in place (`daemon.upgrade`): what the kelpd before this one handed over, and the rest it ran reaped.
    let handover = CommandLine.arguments.firstIndex(of: "--adopt").flatMap { i in CommandLine.arguments.dropFirst(i + 1).first }.flatMap(Handover.take)
    handover?.reapOthers()
    if let stable = Paths.seed { HomeSeed.fill(Paths.root, from: stable) }
    let d = try Daemon(root: Paths.root)
    d.strict()
    try d.start(adopting: handover)
    for s in [SIGTERM, SIGINT, SIGHUP] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { @Sendable in d.stop(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    // Its home deleted or moved away (a test's or a snapshot's temp folder): nobody can reach its socket any more, and an
    // idle daemon has no other reason to end, so it stayed for good (90 of them once, 600 MB).
    let home = open(Paths.root.path, O_EVTONLY)
    if home >= 0 {
        let gone = DispatchSource.makeFileSystemObjectSource(fileDescriptor: home, eventMask: [.delete, .rename], queue: .main)
        gone.setEventHandler { @Sendable in d.stop(); exit(0) }
        gone.resume()
        homeWatch = gone
    }
    // Started by a test process (KELP_TEST_PID, from the tests' isolation): ends with it.
    if let pid = ProcessInfo.processInfo.environment["KELP_TEST_PID"].flatMap(Int32.init) {
        let ended = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        ended.setEventHandler { @Sendable in d.stop(); exit(0) }
        ended.resume()
        testWatch = ended
        if kill(pid, 0) != 0, errno == ESRCH { d.stop(); exit(0) }   // gone before the watch began
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("kelpd: \(Daemon.startFailed(error, root: Paths.root))\n".utf8))
    exit(1)
}
