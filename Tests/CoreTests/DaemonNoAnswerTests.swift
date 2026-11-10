import Foundation
import Testing

@testable import Core

/// A daemon that fails `worktree.list` and answers anything else as delivered.
private func failingItsLists(_ peer: Int32) {
    Thread.detachNewThread {
        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(peer, &chunk, chunk.count)
            guard n > 0 else { return }
            for line in buffer.append(Data(chunk[..<n])) {
                guard let request = try? JSONDecoder().decode(RPCRequest.self, from: line), let id = request.id
                else { continue }
                let said =
                    request.method == WorktreeList.name
                    ? #""error":{"code":-32603,"message":"down"}"# : #""result":{"delivered":1}"#
                Unix.writeAll(peer, Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\(said)}\n".utf8))
            }
        }
    }
}

/// `kelp open` asks which workspace the folder is in. A daemon that failed that is an error to say: it used to be
/// read as "in no workspace", and the file opened wherever the window happened to be.
@Test func aLookupTheDaemonFailedIsAnErrorNotNoWorkspace() async throws {
    let path = NSTemporaryDirectory() + "kelp-noanswer-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    failingItsLists(peer)
    await #expect(throws: RPCError.self) {
        _ = try await IDE.open("f.txt", split: nil, cwd: NSTemporaryDirectory(), client: client)
    }
}
