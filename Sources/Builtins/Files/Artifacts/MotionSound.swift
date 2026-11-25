import AVFoundation
import Core
import Foundation

/// A motion page's sounds put into its video once the frames are written: each `<audio>` at its second, from where its
/// file starts, at its volume with its fades in and out (an audio mix), the picture copied as it is (ProRes keeps its
/// transparency). AVFoundation alone.
enum MotionSound {
    struct Sound: Equatable {
        var file: URL, start: Double, from: Double, length: Double, volume: Float, fadeIn: Double, fadeOut: Double
        /// How many decibels quieter it gets while another sound plays (`data-duck`, music under a voice), and when
        /// those play; the loudness to bring it to at export, in LUFS (`data-loudness`).
        var duck = 0.0, ducks: [ClosedRange<Double>] = [], loudness: Double?

        /// Its volume at second `t` of the page: as set, faded in and out, lower under another sound, with 0.3 s
        /// slopes either side of it.
        func level(at t: Double) -> Float {
            let fade = min(
                fadeIn > 0 ? (t - start) / fadeIn : 1, fadeOut > 0 ? (start + length - t) / fadeOut : 1, 1)
            var under = 0.0
            for r in ducks {
                let edge = min(t - (r.lowerBound - 0.3), (r.upperBound + 0.3) - t) / 0.3
                under = max(under, min(1, max(0, edge)))
            }
            let duckGain = pow(10, -duck * under / 20)
            return volume * Float(max(0, fade) * duckGain)
        }
    }

    /// The page's sounds, their files beside it, timed from second `from` of the page (a work area's start).
    static func sounds(in page: String, folder: URL, from offset: Double = 0) -> [Sound] {
        let sounds = page.matches(of: /<audio\b[^>]*>/).compactMap { tag -> Sound? in
            let text = String(tag.output)
            let value = { (name: String) -> String? in
                guard let at = text.range(of: " \(name)=\""), let end = text[at.upperBound...].firstIndex(of: "\"")
                else { return nil }
                return String(text[at.upperBound..<end])
            }
            guard let src = value("src"), !src.contains("://") else { return nil }
            let number = { (name: String, or: Double) in value(name).flatMap(Double.init) ?? or }
            // Before the work area, its start is cut off.
            let start = number("data-start", 0) - offset, cut = max(0, -start)
            var sound = Sound(
                file: folder.appendingPathComponent(src), start: start + cut, from: number("data-from", 0) + cut,
                length: number("data-duration", .infinity) - cut, volume: Float(number("data-volume", 100) / 100),
                fadeIn: number("data-fade-in", 0), fadeOut: number("data-fade-out", 0))
            sound.duck = number("data-duck", 0)
            sound.loudness = value("data-loudness").flatMap(Double.init)
            return sound
        }
        // A sound that goes quieter does so under the others (those that don't).
        return sounds.map { s in
            var s = s
            if s.duck > 0 {
                s.ducks = sounds.filter { $0.duck == 0 }.map { $0.start...($0.start + min($0.length, 36000)) }
            }
            return s
        }
    }

    /// Writes `video` with `sounds` mixed in to `out` (a new file); false, writing nothing, when none could be read.
    static func mix(_ video: URL, sounds: [Sound], into out: URL) async throws -> Bool {
        let comp = AVMutableComposition(), picture = AVURLAsset(url: video)
        guard let source = try await picture.loadTracks(withMediaType: .video).first,
            let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        let length = try await picture.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
        var levels: [AVMutableAudioMixInputParameters] = []
        let time = { (s: Double) in CMTime(seconds: s, preferredTimescale: 600) }
        for sound in sounds {
            let asset = AVURLAsset(url: sound.file)
            guard let heard = try await asset.loadTracks(withMediaType: .audio).first,
                let into = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let take = min(
                sound.length, try await asset.load(.duration).seconds - sound.from, length.seconds - sound.start)
            guard take > 0 else { continue }
            try into.insertTimeRange(
                CMTimeRange(start: time(sound.from), duration: time(take)), of: heard, at: time(sound.start))
            // Its level a tenth of a second at a time (fades, a voice over it), brought down to its loudness; a file
            // that can't be measured is mixed as it is.
            var gain: Float = 1
            if let target = sound.loudness {
                do { gain = Float(try Self.gain(of: sound.file, to: target) ?? 1) } catch { gain = 1 }
            }
            let level = AVMutableAudioMixInputParameters(track: into)
            var t = sound.start
            level.setVolume(gain * sound.level(at: t), at: time(t))
            while t < sound.start + take {
                let next = min(t + 0.1, sound.start + take)
                level.setVolumeRamp(
                    fromStartVolume: gain * sound.level(at: t), toEndVolume: gain * sound.level(at: next),
                    timeRange: CMTimeRange(start: time(t), end: time(next)))
                t = next
            }
            levels.append(level)
        }
        guard !levels.isEmpty else { return false }
        try await write(comp, picture: track, hint: try await source.load(.formatDescriptions).first, levels, to: out)
        return true
    }

    /// What to multiply `file`'s samples by for it to be `target` LUFS: only ever down, since a mix's volume stops
    /// at 1 (music comes mastered louder than the platforms play it). nil when it can't be measured.
    private static func gain(of file: URL, to target: Double) throws -> Double? {
        let (channels, rate) = try Beats.channels(of: file)
        return Loudness.integrated(channels: channels, rate: rate).map { min(1, pow(10, (target - $0) / 20)) }
    }

    /// Copies the picture as it is and the mixed sound as AAC into `out`, a sample at a time from each, interleaved.
    private static func write(
        _ comp: AVComposition, picture: AVCompositionTrack, hint: CMFormatDescription?,
        _ levels: [AVMutableAudioMixInputParameters], to out: URL
    ) async throws {
        let reader = try AVAssetReader(asset: comp)
        let pictures = AVAssetReaderTrackOutput(track: picture, outputSettings: nil)
        let mix = AVMutableAudioMix()
        mix.inputParameters = levels
        let sound = AVAssetReaderAudioMixOutput(
            audioTracks: comp.tracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
        sound.audioMix = mix
        reader.add(pictures)
        reader.add(sound)
        let writer = try AVAssetWriter(outputURL: out, fileType: out.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        let soundIn = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
        writer.add(pictureIn)
        writer.add(soundIn)
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        var pictureDone = false, soundDone = false
        while !pictureDone || !soundDone {
            guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var moved = false
            if !pictureDone, pictureIn.isReadyForMoreMediaData {
                if let sample = pictures.copyNextSampleBuffer() {
                    pictureIn.append(sample)
                } else {
                    pictureIn.markAsFinished()
                    pictureDone = true
                }
                moved = true
            }
            if !soundDone, soundIn.isReadyForMoreMediaData {
                if let sample = sound.copyNextSampleBuffer() {
                    soundIn.append(sample)
                } else {
                    soundIn.markAsFinished()
                    soundDone = true
                }
                moved = true
            }
            if !moved { await Task.yield() }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
