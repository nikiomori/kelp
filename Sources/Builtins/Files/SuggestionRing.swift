import Core
import Foundation

/// Code from the files lately open or edited, for a model to read beside the file it fills in, so it knows the types
/// and names from them (llama.vim's ring of chunks): each file's start when it opens, and the lines around where you
/// were last asked for a suggestion. Newest last; a piece that overlaps an older one of the same file replaces it.
struct SuggestionRing: Equatable {
    struct Chunk: Equatable {
        let path: String
        /// The lines it covers, 0-based.
        let lines: Range<Int>
        let text: String
    }

    private(set) var chunks: [Chunk] = []
    /// At most this many pieces, of at most `lines` lines and `width` characters each, and `budget` characters sent:
    /// about 2000 tokens, which a small model on a laptop still reads quickly.
    static let most = 16, lines = 64, width = 2000, budget = 6000

    /// Keeps `text`, the file's lines from `first` on, cut to a piece's size.
    mutating func add(path: String, text: String, from first: Int) {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.lines)
        let piece = String(kept.joined(separator: "\n").prefix(Self.width))
        guard !piece.allSatisfy(\.isWhitespace) else { return }
        let range = max(first, 0)..<max(first, 0) + kept.count
        chunks.removeAll { $0.path == path && $0.lines.overlaps(range) }
        chunks.append(Chunk(path: path, lines: range, text: piece))
        if chunks.count > Self.most { chunks.removeFirst(chunks.count - Self.most) }
    }

    /// Keeps the lines around a cursor on `line` (0-based): the end of the code before it and the start of the code
    /// after it, half each, the cursor's own line whole.
    mutating func add(path: String, line: Int, before: String, after: String) {
        let above = before.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.lines / 2)
        let below = after.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.lines / 2)
        let text = (above.joined(separator: "\n")) + (below.joined(separator: "\n"))
        add(path: path, text: text, from: line - above.count + 1)
    }

    /// What goes with a suggestion in `path`: the other files' pieces, the newest that fit the budget, oldest first so
    /// the newest sits nearest the file.
    func extra(for path: String) -> [SuggestChunk] {
        var left = Self.budget, picked: [SuggestChunk] = []
        for chunk in chunks.reversed() where chunk.path != path && chunk.text.count <= left {
            left -= chunk.text.count
            picked.append(SuggestChunk(path: chunk.path, text: chunk.text))
        }
        return picked.reversed()
    }
}
