import Core
import CryptoKit
import Foundation
import SystemConfiguration
import os

// MARK: - The relay's client

extension PhoneBridge {
    /// Returns what the JSON coder or a seal made, or nil with the reason in the log when it failed. A phone can't be
    /// told about such a failure.
    static func sealed<Value>(_ make: () throws -> Value) -> Value? {
        Log.session.attempt("sealing for a phone", make)
    }

    /// One line from the relay. It carries a phone's sealed call, or says that the phone left a stream it held
    /// (`cancel`).
    struct Sent: Decodable {
        var id: String
        var device: String?
        var box: String?
        var cancel: Bool?
    }
    /// The relay refused with `status`. Status 0 means the relay closed the connection.
    private struct Refused: LocalizedError {
        var status: Int
        var errorDescription: String? {
            switch status {
            case 0: "The relay closed the connection."
            case 401: "The relay knows this Mac by another key."
            default: "The relay answered \(status)."
            }
        }
    }

    /// Keeps open the connection that the relay passes calls down, and reconnects by itself. The wait before the next
    /// try doubles after each failure, up to a minute, and drops back to 3 s after a connection that worked.
    func follow(_ relay: Relay) async {
        var pause = 3.0
        while !Task.isCancelled {
            do {
                // The relay sends an empty line every 25 s, so 70 s of silence means the connection is dead.
                let (lines, response) = try await http.bytes(for: relay.request("requests", timeout: 70))
                guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                    throw Refused(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                (connected, failure, pause) = (true, nil, 3)
                let beat = Task { await keepStreamsOpen() }
                defer { beat.cancel() }
                for try await line in lines.lines where !line.isEmpty { serve(line, relay) }
                throw Refused(status: 0)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            connected = false
            cut(streams.keys)
            do { try await Task.sleep(for: .seconds(pause)) } catch { return }
            pause = min(pause * 2, 60)
        }
    }

    /// Writes a newline to every stream every 15 s, because a proxy on the way cuts a silent connection.
    private func keepStreamsOpen() async {
        while true {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            for stream in streams.values { stream.write("\n") }
        }
    }

    /// Handles one line from the relay. Everything up to a call's answer happens here, in the order the lines came, so
    /// a stream is open before the line that closes it is read.
    private func serve(_ line: String, _ relay: Relay) {
        guard let sent = Self.sealed({ try JSONDecoder().decode(Sent.self, from: Data(line.utf8)) }) else { return }
        if sent.cancel == true { return cut([sent.id], telling: false) }
        switch admit(sent) {
        case .refused(let status): post(["id": .string(sent.id), "status": .int(status)], relay)
        case .answer(let box): post(["id": .string(sent.id), "status": .int(200), "box": .string(box)], relay)
        case .events(let stream): open(stream, as: sent.id, relay)
        case .ask(let ask, let device, let key):
            Task {
                let reply = await answer(ask, from: device)
                guard let box = Self.sealed({ try PhoneSeal.seal(reply, about: "r\(Int64(ask.n))", key: key) }) else {
                    return
                }
                post(["id": .string(sent.id), "status": .int(200), "box": .string(box)], relay)
            }
        }
    }

    private nonisolated func post(_ message: [String: JSONValue], _ relay: Relay) {
        Task { await send(message, relay) }
    }

    private nonisolated func send(_ message: [String: JSONValue], _ relay: Relay) async {
        var request = relay.request("responses", timeout: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(message)
            _ = try await http.data(for: request)
        } catch {
            Log.session.error("phone relay: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open(_ stream: Stream, as id: String, _ relay: Relay) {
        let (lines, sending) = AsyncStream.makeStream(of: [String: JSONValue].self)
        var stream = stream
        stream.write = { sending.yield(["id": .string(id), "line": .string($0)]) }
        stream.end = { telling in
            if telling { sending.yield(["id": .string(id), "end": .bool(true)]) }
            sending.finish()
        }
        streams[id] = stream
        sending.yield(["id": .string(id), "stream": .bool(true)])
        Task { for await line in lines { await send(line, relay) } }
    }

    /// Ends the given streams. Pass `telling` when the relay still holds them open, so the phone is told. A phone that
    /// left has already closed its own stream.
    func cut(_ ids: some Sequence<String>, telling: Bool = true) {
        for id in Array(ids) {
            guard let stream = streams.removeValue(forKey: id) else { continue }
            stream.end(telling && connected)
        }
    }

    /// Sends an event to every phone that listens. Each event is sealed with its stream's number and its place in that
    /// stream.
    func say(_ event: String, _ data: JSONValue) {
        for id in Array(streams.keys) {
            guard var stream = streams[id],
                let line = Self.sealed({
                    let box = try PhoneSeal.seal(
                        ["event": .string(event), "data": data] as [String: JSONValue],
                        about: "e\(stream.number).\(stream.sent)", key: stream.key)
                    return try JSONEncoder().encode(["box": box])
                })
            else { continue }
            stream.sent += 1
            streams[id] = stream
            stream.write(String(decoding: line, as: UTF8.self) + "\n")
        }
    }
}
