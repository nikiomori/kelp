import Foundation

/// How loud a sound is as people hear it, in LUFS (ITU-R BS.1770: K-weighted, gated), so a motion page's music can be
/// brought to the level the platforms play at (−14 LUFS for most). Plain Swift on the samples.
public enum Loudness {
    /// The integrated loudness of `samples` (one channel) at `rate`; nil for silence or under 400 ms.
    public static func integrated(_ samples: [Float], rate: Double) -> Double? {
        let weighted = kWeight(samples, rate: rate)
        // Mean squares of 400 ms blocks overlapping by 75%.
        let block = Int(rate * 0.4), step = max(1, block / 4)
        guard block > 0, weighted.count >= block else { return nil }
        var powers: [Double] = []
        var at = 0
        while at + block <= weighted.count {
            var sum = 0.0
            for i in at..<(at + block) { sum += weighted[i] * weighted[i] }
            powers.append(sum / Double(block))
            at += step
        }
        let lufs = { (p: Double) in -0.691 + 10 * log10(p) }
        // Gated twice: blocks under −70 LUFS, then those 10 LU under the loudness of what is left.
        let loud = powers.filter { $0 > 0 && lufs($0) > -70 }
        guard !loud.isEmpty else { return nil }
        let relative = lufs(loud.reduce(0, +) / Double(loud.count)) - 10
        let kept = loud.filter { lufs($0) > relative }
        return lufs(kept.reduce(0, +) / Double(max(kept.count, 1)))
    }

    /// The K-weighting filter (a high shelf, then a high pass) at any rate, the coefficients from BS.1770's
    /// prototypes as libebur128 derives them.
    static func kWeight(_ x: [Float], rate: Double) -> [Double] {
        func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count), x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                y[i] = b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
                (x2, x1, y2, y1) = (x1, x[i], y1, y[i])
            }
            return y
        }
        var f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        var k = tan(Double.pi * f0 / rate), vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = (
            b: [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
            a: [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        )
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / rate)
        a0 = 1 + k / q + k * k
        let pass = (b: [1.0, -2, 1], a: [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
        return biquad(biquad(x.map(Double.init), shelf.b, shelf.a), pass.b, pass.a)
    }
}
