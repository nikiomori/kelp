import AVFoundation
import Accelerate
import AppKit
import Core

/// A motion page's sound (`<audio data-start data-duration src>`): its loudness drawn on its clip, read once from the
/// file beside the page (AVFoundation) and kept for the run.
extension MarkdownTab {
    @MainActor private static var peaks: [String: [Float]] = [:], reading: Set<String> = []
    @MainActor private static var beatsOf: [String: Beats.Found] = [:]

    /// The loudness of `src` (beside the page) from second `from` for `length`, 120 bars; nil until it's read.
    func wave(of src: String, from: Double, length: Double) -> [Float]? {
        let file = url.deletingLastPathComponent().appendingPathComponent(src).standardizedFileURL
        guard let all = Self.peaks[file.path] else {
            if !Self.reading.contains(file.path) {
                Self.reading.insert(file.path)
                Task.detached {
                    var read: [Float] = [], beats: Beats.Found?
                    do {
                        let (all, rate) = try Beats.samples(of: file)
                        (read, beats) = (Self.loudness(all, rate: rate), Beats.find(all, rate: rate))
                    } catch {
                        read = []   // a file AVFoundation can't read has no bars and no beats
                    }
                    await MainActor.run {
                        Self.peaks[file.path] = read
                        if let beats { Self.beatsOf[file.path] = beats }
                        self.runJS("window.kelpMotion?.retell?.()")   // drawn again with its bars
                    }
                }
            }
            return nil
        }
        // The file's bars are 20 a second: the clip's part of them, in 120.
        let first = Int(from * 20), count = max(1, Int(length * 20))
        let part = Array(all.dropFirst(first).prefix(count))
        guard !part.isEmpty else { return [] }
        return (0..<120).map { i in part[min(part.count - 1, i * part.count / 120)] }
    }

    /// A sound's loudness, 20 bars a second, each the loudest sample there (0–1).
    nonisolated static func loudness(_ all: [Float], rate: Double) -> [Float] {
        let step = max(1, Int(rate / 20)), total = all.count
        var out: [Float] = []
        var at = 0
        while at < total {
            var peak: Float = 0
            all.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_maxmgv(base + at, 1, &peak, vDSP_Length(min(step, total - at)))
            }
            out.append(min(1, peak))
            at += step
        }
        return out
    }

    /// A sound's or a video's property from Edit's column: volume (0–100), where it starts in its file, its fades
    /// (seconds); a video's speed and whether it loops.
    func soundMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard kind == "soundProp", let id = body["id"] as? String, let name = body["name"] as? String,
            ["volume", "from", "fade-in", "fade-out", "rate", "loop", "duck", "loudness"].contains(name),
            let asked = body["value"] as? String
        else { return false }
        // Where in the file it starts is within the file: past its end it would play nothing.
        var value = asked
        if name == "from", let from = Double(asked), let length = soundLength(id) {
            value = MarkdownTab.seconds(min(max(from, 0), max(length - 0.1, 0)))
        }
        // What is as if it weren't set goes: a speed of 1, no loop, no fade, the file from its start.
        let plain = name == "rate" ? Double(value) == 1 : name != "volume" && Double(value) == 0
        let edit = HandEdit(board: pageFile, id: id, what: name, from: nil, to: value)
        rewritePage(edit) { BoardEdit.setAttribute($0, id: id, name: "data-" + name, value: plain ? nil : value) }
        return true
    }

    /// How long element `id`'s sound file plays, in seconds; nil when it doesn't read.
    private func soundLength(_ id: String) -> Double? {
        guard let src = BoardEdit.attribute(editor.text, id: id, name: "src"),
            let file = try? AVAudioFile(forReading: url.deletingLastPathComponent().appendingPathComponent(src))
        else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// The beats of the page's first sound, at the page's seconds (once its file is read).
    func pageBeats() -> [Double] {
        guard let sound = MotionSound.sounds(in: editor.text, folder: url.deletingLastPathComponent()).first,
            let found = Self.beatsOf[sound.file.standardizedFileURL.path]
        else { return [] }
        return found.times.filter { $0 >= sound.from && $0 < sound.from + sound.length }.map {
            sound.start + $0 - sound.from
        }
    }

    /// The page's sounds follow it: Kelp plays them itself (WebKit plays no file beside a page), each from where its
    /// clip is, at its volume and fades, while the page plays; still when it stops.
    /// While it stands, a moved time (the playhead dragged, a click on the timeline) plays an eighth of a second of
    /// what sounds there, as an editor scrubs, so a cut is found by ear.
    func followSound(playing: Bool, at time: Double) {
        let player = SoundPlayer.of(self)
        let sounds = MotionSound.sounds(in: editor.text, folder: url.deletingLastPathComponent())
        guard playing else { return player.scrub(sounds, at: time) }
        player.follow(sounds, at: time, rate: motionStudio.playbackRate)
    }
}

/// The sounds of one tab, as AVAudioPlayers that follow the page's time.
@MainActor
final class SoundPlayer {
    private static let byTab = NSMapTable<MarkdownTab, SoundPlayer>.weakToStrongObjects()
    private var players: [URL: AVAudioPlayer] = [:]

    static func of(_ tab: MarkdownTab) -> SoundPlayer {
        if let made = byTab.object(forKey: tab) { return made }
        let made = SoundPlayer()
        byTab.setObject(made, forKey: tab)
        return made
    }

    /// Whether any of the tab's sounds is playing now.
    var sounding: Bool { players.values.contains(where: \.isPlaying) }

    /// The time last heard standing, and the short play a scrub started.
    private var stoodAt: Double?, blip: Task<Void, any Error>?

    /// Plays an eighth of a second of `sounds` at `t` when the time moved while the page stands; none the first time.
    func scrub(_ sounds: [MotionSound.Sound], at t: Double) {
        defer { stoodAt = t }
        guard let was = stoodAt, abs(was - t) > 0.01 else { return follow([], at: t, rate: 1) }
        blip?.cancel()
        follow(sounds, at: t, rate: 1)
        blip = Task { [weak self] () throws in
            try await Task.sleep(for: .milliseconds(120))   // throws once a newer scrub cancels it
            self?.follow([], at: t, rate: 1)
        }
    }

    /// Plays each of `sounds` that is in its time at `at`, from the right place; stops the rest (all, with none).
    func follow(_ sounds: [MotionSound.Sound], at t: Double, rate: Double) {
        var heard = Set<URL>()
        for sound in sounds where t >= sound.start && t < sound.start + sound.length {
            heard.insert(sound.file)
            let player: AVAudioPlayer
            do { player = try self.player(sound.file) } catch { continue }   // a file it can't play stays silent
            player.volume = sound.level(at: t)
            player.rate = Float(rate)
            let want = sound.from + (t - sound.start)
            if !player.isPlaying {
                player.currentTime = want
                player.play()
            } else if abs(player.currentTime - want) > 0.25 {
                player.currentTime = want
            }
        }
        for (file, player) in players where !heard.contains(file) && player.isPlaying { player.pause() }
    }

    private func player(_ file: URL) throws -> AVAudioPlayer {
        if let made = players[file] { return made }
        let made = try AVAudioPlayer(contentsOf: file)
        made.enableRate = true
        made.prepareToPlay()
        players[file] = made
        return made
    }
}
