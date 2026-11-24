import Core
import Foundation

extension Main {
    /// `artifact beats <name>`: the beats of a motion page's first sound, at the page's seconds, so the agent can put
    /// its scene changes on them.
    static func beats(_ cwd: String, _ c: RPCClient) async throws {
        let usage = "artifact beats <name>"
        let (target, _) = try await page(args.first, root: try await projectRoot(cwd, c), usage: usage)
        guard let data = FileManager.default.contents(atPath: target) else { fail("can't read \(target)") }
        let page = String(decoding: data, as: UTF8.self)
        guard let tag = page.firstMatch(of: /<audio\b[^>]*>/)?.output,
            let src = tag.firstMatch(of: /\ssrc="([^"]+)"/)?.output.1
        else { fail("no <audio> on the page: add the music first (drop a file on the stage, or write the tag)") }
        let number = { (name: String) -> Double? in
            guard let at = tag.range(of: " \(name)=\""), let end = tag[at.upperBound...].firstIndex(of: "\"") else {
                return nil
            }
            return Double(tag[at.upperBound..<end])
        }
        let file = URL(fileURLWithPath: target).deletingLastPathComponent().appendingPathComponent(String(src))
        let (samples, rate) = try Beats.samples(of: file)
        guard let found = Beats.find(samples, rate: rate) else { fail("no beat found in \(src)") }
        let start = number("data-start") ?? 0, from = number("data-from") ?? 0
        let length = number("data-duration") ?? .infinity
        let times = found.times.filter { $0 >= from && $0 < from + length }.map {
            String(format: "%.2f", start + $0 - from)
        }
        print("\(String(format: "%g", found.bpm)) BPM · \(times.count) beats: " + times.joined(separator: " "))
    }
}
