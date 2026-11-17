import Core
import Foundation
import os

/// The daemon's log, for what would otherwise fail without a trace. Read it in Console.app or with
/// `log stream --predicate 'subsystem == "dev.kelp.daemon"'`. It never holds terminal output, prompts, tokens or file
/// contents. Paths and messages stay private in the system log unless marked public.
enum Log {
    static let start = Logger(subsystem: "dev.kelp.daemon", category: "start")
    static let store = Logger(subsystem: "dev.kelp.daemon", category: "store")
    static let rpc = Logger(subsystem: "dev.kelp.daemon", category: "rpc")
    static let session = Logger(subsystem: "dev.kelp.daemon", category: "session")
    static let vm = Logger(subsystem: "dev.kelp.daemon", category: "vm")
}
