import AppKit
import ApplicationServices

// Kelp Guest: inside a Kelp macOS machine, its apps' controls by name. The screen itself (screenshots, clicks, keys) is
// read and driven from the Mac's side by kelp-vm and needs nothing in here; this needs Accessibility, asked for the
// first time `ui` runs. Started at login (a LaunchAgent); run over SSH with arguments, the same program asks it:
//   KelpGuest ui [--app NAME]             the front app's controls, a line each, with refs: "- button "Save" [ref=e12]"
//   KelpGuest press REF|TITLE             presses a control through Accessibility: no pointer
//   KelpGuest status                      whether it has Accessibility

setvbuf(stdout, nil, _IOLBF, 0)
let socketPath = NSTemporaryDirectory() + "kelp-guest.sock"
let argv = Array(CommandLine.arguments.dropFirst())

if argv.isEmpty {
    MainActor.assumeIsolated {   // top-level code runs on the main thread
        let server = Server(socket: socketPath)
        server.start()
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(server) { NSApplication.shared.run() }
    }
} else {
    exit(Client.ask(argv, socket: socketPath))
}
