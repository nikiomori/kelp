import AVFoundation
import Accelerate
import AppKit
import Core

/// A motion page's sound (`<audio data-start data-duration src>`): its loudness drawn on its clip, read once from the
/// file beside the page (AVFoundation) and kept for the run.
extension MarkdownTab {
    @MainActor private static var peaks: [String: [Float]] = [:], reading: Set<String> = []

    /// The loudness of `src` (beside the page) from second `from` for `length`, 120 bars; nil until it's read.
    func wave(of src: String, from: Double, length: Double) -> [Float]? {
        let file = url.deletingLastPathComponent().appendingPathComponent(src).standardizedFileURL
        guard let all = Self.peaks[file.path] else {
            if !Self.reading.contains(file.path) {
                Self.reading.insert(file.path)
                Task.detached {
                    let read = Self.loudness(of: file)
                    await MainActor.run {
                        Self.peaks[file.path] = read
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

    /// The file's loudness, 20 bars a second, each the loudest sample there (0–1); empty when it doesn't read.
    nonisolated static func loudness(of file: URL) -> [Float] {
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) } catch { return [] }   // one AVFoundation can't read: no bars
        guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.fileFormat.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length))
        else { return [] }
        do { try audio.read(into: buffer) } catch { return [] }
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let step = max(1, Int(audio.fileFormat.sampleRate / 20)), total = Int(buffer.frameLength)
        var out: [Float] = []
        var at = 0
        while at < total {
            var peak: Float = 0
            vDSP_maxmgv(samples + at, 1, &peak, vDSP_Length(min(step, total - at)))
            out.append(min(1, peak))
            at += step
        }
        return out
    }

    /// A sound's property from Edit's column: volume (0–100), where it starts in its file, its fades (seconds).
    func soundMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        guard kind == "soundProp", let id = body["id"] as? String, let name = body["name"] as? String,
            ["volume", "from", "fade-in", "fade-out"].contains(name), let value = body["value"] as? String
        else { return false }
        let edit = HandEdit(board: pageFile, id: id, what: name, from: nil, to: value)
        rewritePage(edit) {
            BoardEdit.setAttribute(
                $0, id: id, name: "data-" + name, value: Double(value) == 0 && name != "volume" ? nil : value)
        }
        return true
    }

    /// The page's sounds follow it: Kelp plays them itself (WebKit plays no file beside a page), each from where its
    /// clip is, at its volume and fades, while the page plays; still when it stops.
    func followSound(playing: Bool, at time: Double) {
        let sounds = playing ? MotionSound.sounds(in: editor.text, folder: url.deletingLastPathComponent()) : []
        SoundPlayer.of(self).follow(sounds, at: time, rate: motionStudio.playbackRate)
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

    /// Plays each of `sounds` that is in its time at `at`, from the right place; stops the rest (all, with none).
    func follow(_ sounds: [MotionSound.Sound], at t: Double, rate: Double) {
        var heard = Set<URL>()
        for sound in sounds where t >= sound.start && t < sound.start + sound.length {
            heard.insert(sound.file)
            let player: AVAudioPlayer
            do { player = try self.player(sound.file) } catch { continue }   // a file it can't play stays silent
            let ramp = min(
                sound.fadeIn > 0 ? (t - sound.start) / sound.fadeIn : 1,
                sound.fadeOut > 0 ? (sound.start + sound.length - t) / sound.fadeOut : 1, 1)
            player.volume = sound.volume * Float(max(0, ramp))
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
