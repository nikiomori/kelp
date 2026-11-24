import AVFoundation
import Foundation

/// The beat of a piece of music (OpenMotion's beat grid), from its samples: how loud it gets from moment to moment
/// (an onset envelope, 1024-sample frames 256 apart), the tempo that envelope repeats at most (60–180 BPM, a little
/// preference for 80–160), and where the beats fall (the offset whose beats are loudest). Plain Swift: the app draws
/// them on the timeline and clips snap to them; `kelp artifact beats` gives them to the agent.
public enum Beats {
    public struct Found: Equatable, Sendable {
        public var bpm: Double, times: [Double]
    }

    public static func find(_ samples: [Float], rate: Double) -> Found? {
        let frame = 1024, hop = 256
        guard samples.count > frame * 4, rate > 0 else { return nil }
        // How much louder each frame is than the one before (only rises count).
        var energy: [Double] = []
        var at = 0
        while at + frame <= samples.count {
            var sum: Float = 0
            for i in at..<(at + frame) { sum += samples[i] * samples[i] }
            energy.append(log(1 + Double(sum)))
            at += hop
        }
        let rise = zip(energy.dropFirst(), energy).map { max(0, $0 - $1) }
        let perSecond = rate / Double(hop)
        let shortest = Int(perSecond * 60 / 180), longest = Int(perSecond * 60 / 60)
        guard rise.count > longest * 2, shortest > 0 else { return nil }
        // The lag the envelope matches itself at best is the beat, made finer between whole frames (a parabola
        // through the best score and its neighbours).
        let score = { (lag: Int) -> Double in
            var sum = 0.0
            for i in 0..<(rise.count - lag) { sum += rise[i] * rise[i + lag] }
            let bpm = 60 * perSecond / Double(lag)
            return sum * ((80...160).contains(bpm) ? 1.1 : 1)
        }
        let scores = (shortest - 1...longest + 1).map { score(max(1, $0)) }
        guard let peak = (1..<scores.count - 1).max(by: { scores[$0] < scores[$1] }) else { return nil }
        let (l, m, r) = (scores[peak - 1], scores[peak], scores[peak + 1])
        let bend = l - 2 * m + r == 0 ? 0 : 0.5 * (l - r) / (l - 2 * m + r)
        let lag = Double(peak + shortest - 1) + max(-0.5, min(0.5, bend))
        // Where the beats fall: the offset whose beats rise most.
        var offset = (at: 0, sum: -1.0)
        for start in 0..<Int(lag.rounded(.up)) {
            let sum = stride(from: Double(start), to: Double(rise.count), by: lag).reduce(0) { $0 + rise[Int($1)] }
            if sum > offset.sum { offset = (start, sum) }
        }
        // Each beat on the rise nearest it, then the straight line through them (least squares): the grid.
        let window = Int(lag / 4)
        let hits = stride(from: Double(offset.at), to: Double(rise.count), by: lag).map { at -> Double in
            let lo = max(0, Int(at) - window), hi = min(rise.count - 1, Int(at) + window)
            return Double((lo...hi).max { rise[$0] < rise[$1] } ?? Int(at))
        }
        let n = Double(hits.count), ks = hits.indices.map(Double.init)
        let mk = ks.reduce(0, +) / n, mh = hits.reduce(0, +) / n
        let spread = ks.reduce(0) { $0 + ($1 - mk) * ($1 - mk) }
        let slope = zip(ks, hits).reduce(0) { $0 + ($1.0 - mk) * ($1.1 - mh) } / max(1e-9, spread)
        let start = mh - slope * mk
        // A rise in frame i+1 is a sound that started inside its last hop: that hop's middle.
        let time = { (index: Double) in ((index + 1) * Double(hop) + Double(frame - hop) + Double(hop) / 2) / rate }
        let step = slope / perSecond, first = time(start)
        let length = Double(samples.count) / rate
        let times = stride(from: first, to: length, by: step).map { ($0 * 100).rounded() / 100 }
        return Found(bpm: (60 / step * 10).rounded() / 10, times: times)
    }

    /// A sound file's channels, mixed into one, and its sample rate.
    public static func samples(of file: URL) throws -> (samples: [Float], rate: Double) {
        let (all, rate) = try channels(of: file)
        guard all.count > 1 else { return (all.first ?? [], rate) }
        let scale = 1 / Float(all.count)
        return (all[0].indices.map { i in all.reduce(0) { $0 + $1[i] } * scale }, rate)
    }

    /// Each channel of a sound file, read in the file's own layout (a mono buffer can't take a stereo file), and its
    /// sample rate.
    public static func channels(of file: URL) throws -> (channels: [[Float]], rate: Double) {
        let audio = try AVAudioFile(forReading: file)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try audio.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(buffer.frameLength)
        let all = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: count))
        }
        return (all, audio.processingFormat.sampleRate)
    }
}
