import CoreServices
import Foundation

/// Watches a directory tree with FSEvents, debounced. It reports the changed absolute paths on `deliver` (the main
/// thread by default, while the daemon's watches use a queue of their own), or reports what happened to each path
/// (`init(changesIn:)`). Build output under the root (node_modules, .build…, which are ignored and never in the tree)
/// is dropped first, on the stream's own queue. That is because a build or an `npm install` writes thousands of files a
/// second, and every watcher of the folder used to sort through them on the main thread. Limit: the list of usual build
/// folders is fixed, so a tracked folder with such a name updates only when something else changes.
public final class FileWatcher: @unchecked Sendable {   // Its FSEventStream starts here and stops on its own queue.
    static let buildFolders: Set<Substring> = [
        "node_modules", ".build", "DerivedData", ".next", "__pycache__", ".gradle", ".swiftpm", ".venv", "target"
    ]
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.kelp.filewatcher")
    /// The object the callback reads. It isn't the watcher itself, because a callback holding the last reference would
    /// run the watcher's deinit on the stream's queue, where `queue.sync` traps.
    private final class Sink: Sendable {
        let roots: [String], deliver: DispatchQueue, handler: @Sendable ([Change]) -> Void
        init(_ roots: [String], _ deliver: DispatchQueue, _ handler: @escaping @Sendable ([Change]) -> Void) {
            self.roots = roots
            self.deliver = deliver
            self.handler = handler
        }
    }
    private let sink: Sink

    /// An event for one path, with what FSEvents says happened to it (`kFSEventStreamEventFlag…`).
    public struct Change: Sendable, Equatable {
        public let path: String, flags: FSEventStreamEventFlags
        public init(path: String, flags: FSEventStreamEventFlags) {
            self.path = path
            self.flags = flags
        }

        /// Whether the event may have added, removed or moved something, rather than only changing what a file holds.
        /// That is an item created, removed or renamed (an atomic save is a rename). It is also an event that names no
        /// item (history dropped, a folder to scan again, a volume mounted or gone), which could be anything.
        public var reshapes: Bool {
            flags & Self.moved != 0 || flags & Self.itemFlags == 0
        }
        static let moved = [
            kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemRenamed,
            kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount,
            kFSEventStreamEventFlagUnmount
        ].reduce(FSEventStreamEventFlags(0)) { $0 | FSEventStreamEventFlags($1) }
        /// All the `kFSEventStreamEventFlagItem…` flags, from created (0x100) through cloned (0x400000).
        public static let itemFlags: FSEventStreamEventFlags = 0x7F_FF00
    }

    public convenience init?(
        root: String, latency: Double = 0.25, deliver: DispatchQueue = .main,
        handler: @escaping @Sendable ([String]) -> Void
    ) {
        self.init(changesIn: root, latency: latency, deliver: deliver) { handler($0.map(\.path)) }
    }

    public init?(
        changesIn root: String, latency: Double = 0.25, deliver: DispatchQueue = .main,
        _ handler: @escaping @Sendable ([Change]) -> Void
    ) {
        sink = Sink(
            Array(Set([root, Paths.real(root) ?? root].map { $0.hasSuffix("/") ? $0 : $0 + "/" })), deliver, handler)
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, n, paths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let kept = zip(arr.prefix(n), UnsafeBufferPointer(start: flags, count: n)).compactMap { path, flags in
                FileWatcher.isBuildOutput(path, under: sink.roots) ? nil : Change(path: path, flags: flags)
            }
            guard !kept.isEmpty else { return }
            let handler = sink.handler
            sink.deliver.async { handler(kept) }
        }
        guard
            let created = FSEventStreamCreate(
                nil, cb, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                        | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public static func isBuildOutput(_ path: String, under roots: [String]) -> Bool {
        guard let root = roots.first(where: path.hasPrefix) else { return false }
        return path.dropFirst(root.count).split(separator: "/").contains(where: buildFolders.contains)
    }

    deinit {
        // This runs on the stream's queue, which never runs the watcher's code, only a Sink's. Once it returns, no
        // callback runs or can start, so the sink isn't read after it is gone.
        if let stream {
            queue.sync {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }
}
