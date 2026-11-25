import AppKit
import DesignKit

/// Closing an empty stretch between scenes (OpenMotion's Close Gap): the scenes after it, and the layers and the
/// animations that start after it, move left by its length, as one edit.
extension MotionTimeline {
    /// The empty stretches between scenes, and before the first one.
    static func gaps(in scenes: [Clip]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = [], end = 0.0
        for scene in scenes.sorted(by: { $0.start < $1.start }) {
            if scene.start - end > 0.01 { out.append(end...scene.start) }
            end = max(end, scene.end)
        }
        return out
    }

    /// Each clip that starts after one of `gaps`, moved left by the length of those before it.
    static func closing(_ gaps: [ClosedRange<Double>], _ clips: [Clip]) -> [(was: Clip, now: Clip)] {
        clips.compactMap { clip in
            let shift = gaps.filter { $0.upperBound <= clip.start + 0.001 }.reduce(0) {
                $0 + $1.upperBound - $1.lowerBound
            }
            guard shift > 0 else { return nil }
            var now = clip
            now.start -= shift
            return (clip, now)
        }
    }

    /// The menu of an empty stretch of the scenes' lane at `p`: Close Gap, Close All Gaps.
    func gapMenu(at p: NSPoint) -> NSMenu? {
        guard laneRect(0).contains(p) else { return nil }
        let t = seconds(p.x), all = Self.gaps(in: scenes)
        guard let gap = all.first(where: { $0.contains(t) }) else { return nil }
        let menu = NSMenu(), clips = scenes + tracks.filter { !$0.id.isEmpty }
        menu.add(String(localized: "Close Gap")) { [weak self] in self?.onGroup?(Self.closing([gap], clips)) }
        menu.add(String(localized: "Close All Gaps")) { [weak self] in self?.onGroup?(Self.closing(all, clips)) }
        return menu
    }
}
