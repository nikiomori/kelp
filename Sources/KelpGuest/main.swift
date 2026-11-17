import AppKit
import ApplicationServices

// Kelp Guest runs inside a Kelp macOS machine and finds the controls of the machine's apps by name. kelp-vm reads and
// drives the screen itself (screenshots, clicks, keys) from the Mac's side, so none of that lives here. This program
// needs Accessibility, which macOS asks for the first time `ui` runs. A LaunchAgent starts it at login as a server.
// Run over SSH with arguments, the same program sends the request to that server:
//   KelpGuest ui [--app NAME]             the front app's controls, a line each, with refs: "- button "Save" [ref=e12]"
//   KelpGuest press REF|TITLE             presses a control through Accessibility, without moving the pointer
//   KelpGuest status                      says whether the server has Accessibility

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
