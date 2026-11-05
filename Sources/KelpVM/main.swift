import Foundation
import Core

// kelp-vm <machine folder>: runs one of Kelp's virtual machines for kelpd (Core/VMs.swift). The only program that holds
// the virtualization entitlement; it keeps running while its machine sleeps, so the next SSH connection wakes it.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: kelp-vm <machine folder>\n".utf8)); exit(2)
}
setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let runtime: Runtime
do { runtime = try Runtime(folder: URL(fileURLWithPath: CommandLine.arguments[1])) } catch { log("can't start: \(error)"); exit(1) }
runtime.listen()
RunLoop.main.run()   // not dispatchMain(): that ends the main thread, and the main queue (the VM's, MainActor's) would run elsewhere
