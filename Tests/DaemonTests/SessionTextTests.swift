import Foundation
import Testing

@testable import Daemon

/// A command's short name, from commands agents really ran.
@Test func aCommandIsCalledByItsProgram() {
    for (command, name) in [
        ("swift build --scratch-path /tmp/kelp-build/A --product kelp > /private/tmp/out.log 2>&1", "swift build"),
        ("cd /private/tmp/claude-501/x && swift test --filter 'AgentsTests|CoreTests'", "swift test"),
        ("export KELP_V1='release'; make release", "make release"),
        ("/private/tmp/claude-501/scratchpad/run.sh 2>&1 | tee run.out", "run.sh"),
        ("./Scripts/make-app.sh", "make-app.sh"),
        ("for i in 1 2 3; do swift test --filter x; done", "swift test"),
        ("KELP_HOME=/tmp/k /tmp/debug/KelpApp", "KelpApp"),
        ("npm run dev -- --port 3000", "npm run dev"),
        ("python3 -m pytest", "python3"),
        ("sleep 30", "sleep"),
        ("(cd web && pnpm build)", "pnpm build"),
        ("exec cat", "cat"),
        ("cd /tmp", "cd /tmp")
    ] { #expect(CommandName.of(command) == name, "\(command)") }
}

/// Each folder keeps its own ten ports, the same each run, and two folders never share a block.
@Test func everyFolderHasItsOwnPorts() {
    let folders = (1...200).map { "/projects/app-\($0)" }
    let ports = folders.map { PortBlocks.port(for: $0, among: folders) }
    #expect(Set(ports).count == folders.count)
    #expect(ports.allSatisfy { $0 >= 20_000 && $0 + 9 < 49_152 && $0 % 10 == 0 })   // under the ephemeral range
    #expect(PortBlocks.first + PortBlocks.count * PortBlocks.size <= 49_152)
    #expect(PortBlocks.port(for: folders[7], among: folders.reversed()) == ports[7])   // not the list's order
}

/// A chunk cut inside a character keeps its start for the next one; a whole one is left as it is.
@Test func aCharacterCutBetweenChunksIsKeptForTheNext() {
    let bytes = Data("a…b🙂".utf8)   // … is 3 bytes, 🙂 4
    let (whole, rest) = UTF8Chunks.split(bytes.prefix(3))   // "a" + 2 of …'s 3
    #expect(whole == Data("a".utf8) && rest.count == 2)
    #expect(String(decoding: rest + bytes[3..<5], as: UTF8.self) == "…b")
    #expect(UTF8Chunks.split(bytes).rest.isEmpty && UTF8Chunks.split(bytes.prefix(bytes.count - 1)).rest.count == 3)
    #expect(UTF8Chunks.split(Data()).whole.isEmpty && UTF8Chunks.split(Data([0x80, 0x80, 0x80, 0x80])).rest.isEmpty)
}
