import Core
import Foundation

extension Main {
    /// A motion page's `beats` or `captions`.
    static func motion(_ sub: String, _ cwd: String, _ c: RPCClient) async throws {
        if sub == "beats" { try await beats(cwd, c) } else { try await captions(cwd, c) }
    }

    /// `artifact beats <name>`: the beats of a motion page's first sound, at the page's seconds, so the agent can put
    /// its scene changes on them.
    static func beats(_ cwd: String, _ c: RPCClient) async throws {
        let usage = "artifact beats <name>"
        let (target, _) = try await page(args.first, root: try await projectRoot(cwd, c), usage: usage)
        guard let data = FileManager.default.contents(atPath: target) else { fail("can't read \(target)") }
        guard let (bpm, times) = try pageBeats(String(decoding: data, as: UTF8.self), at: target) else {
            fail("no <audio> on the page: add the music first (drop a file on the stage, or write the tag)")
        }
        let shown = times.map { String(format: "%.2f", $0) }
        print("\(String(format: "%g", bpm)) BPM · \(times.count) beats: " + shown.joined(separator: " "))
    }

    /// The tempo of `page`'s first sound and its beats at the page's seconds; nil when it has no sound.
    static func pageBeats(_ page: String, at target: String) throws -> (bpm: Double, times: [Double])? {
        guard let tag = page.firstMatch(of: /<audio\b[^>]*>/)?.output,
            let src = tag.firstMatch(of: /\ssrc="([^"]+)"/)?.output.1
        else { return nil }
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
        return (found.bpm, found.times.filter { $0 >= from && $0 < from + length }.map { start + $0 - from })
    }

    /// `artifact captions <name> --text <file> [--from s] [--to s]`: a motion page's subtitles from a script, a line
    /// each, shared over the page (or from…to) by length, their edges on the music's beats where one is near.
    static func captions(_ cwd: String, _ c: RPCClient) async throws {
        let usage = "artifact captions <name> --text <file, a subtitle a line> [--from <s>] [--to <s>]"
        guard let script = flag("--text") else { fail(usage) }
        let from = flag("--from").flatMap(Double.init), to = flag("--to").flatMap(Double.init)
        let (target, _) = try await page(args.first, root: try await projectRoot(cwd, c), usage: usage)
        guard let data = FileManager.default.contents(atPath: target),
            let typed = FileManager.default.contents(atPath: (script as NSString).expandingTildeInPath)
        else { fail("can't read \(target) or \(script)") }
        let page = String(decoding: data, as: UTF8.self)
        let length = page.firstMatch(of: /<body\b[^>]*\sdata-duration="([0-9.]+)"/).flatMap { Double($0.output.1) }
        let span = (from ?? 0)...max((from ?? 0) + 1, to ?? length ?? 5)
        let beats = try pageBeats(page, at: target)?.times ?? []
        let cues = Captions.timed(String(decoding: typed, as: UTF8.self), over: span, beats: beats)
        guard !cues.isEmpty else { fail("no lines in \(script)") }
        try Data(Captions.write(page, cues: cues).utf8).write(to: URL(fileURLWithPath: target), options: .atomic)
        print(
            "\(cues.count) subtitles from \(String(format: "%.2f", span.lowerBound)) to "
                + "\(String(format: "%.2f", span.upperBound)) s" + (beats.isEmpty ? "." : ", on the beats."))
    }
}
