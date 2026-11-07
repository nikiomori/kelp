import CoreServices
import Foundation

/// FSEvents on a directory tree, debounced; reports changed absolute paths on `deliver` (the main thread by default; the
/// daemon's watches take a queue of their own). Build output under the root (node_modules, .build…: ignored, never in
/// the tree) is dropped on the stream's own queue first: a build or an `npm install` writes thousands of files a second,
/// and every watcher of the folder sorted through them on main.
/// Limit: a fixed list of usual build folders; a tracked folder named like one updates on the next other change.
public final class FileWatcher: @unchecked Sendable {   // holds an FSEventStream: started here, stopped on its own queue
    static let buildFolders: Set<Substring> = [
        "node_modules", ".build", "DerivedData", ".next", "__pycache__", ".gradle", ".swiftpm", ".venv", "target"
    ]
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.kelp.filewatcher")
    /// What the callback reads. Not the watcher itself: a callback holding the last reference would run its deinit on
    /// the stream's queue, where `queue.sync` traps.
    private final class Sink: Sendable {
        let roots: [String], deliver: DispatchQueue, handler: @Sendable ([String]) -> Void
        init(_ r: [String], _ q: DispatchQueue, _ h: @escaping @Sendable ([String]) -> Void) {
            roots = r
            deliver = q
            handler = h
        }
    }
    private let sink: Sink

    public init?(
        root: String, latency: Double = 0.25, deliver: DispatchQueue = .main,
        handler: @escaping @Sendable ([String]) -> Void
    ) {
        sink = Sink(
            Array(Set([root, Paths.real(root) ?? root].map { $0.hasSuffix("/") ? $0 : $0 + "/" })), deliver, handler)
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let kept = arr.prefix(n).filter { !FileWatcher.isBuildOutput($0, under: sink.roots) }
            guard !kept.isEmpty else { return }
            let handler = sink.handler
            sink.deliver.async { handler(kept) }
        }
        guard
            let s = FSEventStreamCreate(
                nil, cb, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                        | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public static func isBuildOutput(_ path: String, under roots: [String]) -> Bool {
        guard let root = roots.first(where: path.hasPrefix) else { return false }
        return path.dropFirst(root.count).split(separator: "/").contains(where: buildFolders.contains)
    }

    deinit {
        // On the stream's queue (never this one: only a Sink is seen there): once it returns no callback runs or can
        // start, so the sink isn't read after it's gone.
        if let s = stream {
            queue.sync {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
        }
    }
}
