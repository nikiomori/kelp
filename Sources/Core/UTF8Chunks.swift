import Foundation

/// Output read in chunks can end inside a character (a read of 64 KB cuts "…" in two): decoded alone, each half would
/// read as U+FFFD. The cut-off bytes are kept for the next chunk instead.
public enum UTF8Chunks {
    /// `data` split into what decodes whole and the start of a character it ends in (at most 3 bytes).
    public static func split(_ data: Data) -> (whole: Data, rest: Data) {
        let end = data.endIndex
        var cut = end
        while cut > data.startIndex, end - cut < 3, data[data.index(before: cut)] & 0xC0 == 0x80 {
            cut = data.index(before: cut)
        }
        guard cut > data.startIndex else { return (data, Data()) }
        let lead = data[data.index(before: cut)], start = data.index(before: cut)
        let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return end - start < length ? (data[..<start], data[start...]) : (data, Data())
    }
}
