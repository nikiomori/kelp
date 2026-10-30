import Foundation
import Core
import Daemon

// kelpd: background daemon. Run by launchd (see `kelp install`) or started on demand by the app/CLI.
if CommandLine.arguments.contains("--can-adopt") { print(Handover.canAdopt); exit(0) }   // asked before an update execs this
signal(SIGPIPE, SIG_IGN)
// launchd gives 256 fds; every agent holds 3, every open terminal 2 more, every git or gh run 2: take what's allowed.
var files = rlimit()
if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < rlim_t(OPEN_MAX) {
    files.rlim_cur = min(files.rlim_max, rlim_t(OPEN_MAX)); setrlimit(RLIMIT_NOFILE, &files)
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []   // must outlive this scope or the handlers vanish
do {
    // An update's exec in place (`daemon.upgrade`): what the kelpd before this one handed over, and the rest it ran reaped.
    let handover = CommandLine.arguments.firstIndex(of: "--adopt").flatMap { i in CommandLine.arguments.dropFirst(i + 1).first }.flatMap(Handover.take)
    handover?.reapOthers()
    if let stable = Paths.seed { HomeSeed.fill(Paths.root, from: stable) }
    let d = try Daemon(root: Paths.root)
    try d.start(adopting: handover)
    for s in [SIGTERM, SIGINT, SIGHUP] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { @Sendable in d.stop(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("kelpd: \(Daemon.startFailed(error, root: Paths.root))\n".utf8))
    exit(1)
}
