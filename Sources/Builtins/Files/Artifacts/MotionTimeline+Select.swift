import AppKit
import DesignKit

/// Several clips at once: a box dragged over the lanes' empty room takes in every clip it touches, ⇧-click adds or
/// takes away one, [ and ] take every clip before or after the time. The clips taken move together when one of them
/// is dragged (`onGroup`, one edit), and ⌫ ⌘C ⌘X act on all of them (`onMany`). With the keyboard, Space lifts the
/// element lane clicked last, ↑ ↓ carry it among the layers, ↩ sets it down and Esc puts it back.
extension MotionTimeline {
    struct Selecting {
        var ids: Set<String> = []
        var box: (from: NSPoint, to: NSPoint)?
        var group: (from: Double, by: Double)?
    }

    private var allClips: [(clip: Clip, lane: Int)] {
        scenes.map { ($0, 0) } + tracks.enumerated().map { ($0.element, $0.offset + 1) }
    }

    /// A clip as it shows now: moved with its group while the group is dragged.
    func shown(_ clip: Clip) -> Clip {
        guard let group = selecting.group, selecting.ids.contains(clip.id) else { return clip }
        var moved = clip
        moved.start = max(clip.start + group.by, 0)
        return moved
    }

    /// A press: ⇧ on a clip adds or takes it away; on a clip of a group, the group's drag; on empty room, a box.
    /// Returns whether it took the press.
    func selectDown(at point: NSPoint, shift: Bool) -> Bool {
        let hit = allClips.first { box($0.clip, lane: $0.lane).insetBy(dx: -3, dy: 0).contains(point) }?.clip
        if let hit, shift {
            if selecting.ids.remove(hit.id) == nil { selecting.ids.insert(hit.id) }
            needsDisplay = true
            return true
        }
        if let hit, selecting.ids.contains(hit.id), selecting.ids.count > 1 {
            selecting.group = (seconds(point.x), 0)
            window?.makeFirstResponder(self)
            return true
        }
        if hit == nil, point.x >= track.minX, point.y > Self.ruler + marksLane {
            selecting.box = (point, point)
            window?.makeFirstResponder(self)
            return true
        }
        selecting.ids = hit.map { [$0.id] } ?? []
        return false
    }

    func selectDragged(to point: NSPoint) -> Bool {
        if selecting.box != nil {
            selecting.box?.to = point
        } else if let group = selecting.group {
            selecting.group?.by = ((seconds(point.x) - group.from) * 10).rounded() / 10
        } else {
            return false
        }
        needsDisplay = true
        return true
    }

    func selectUp() -> Bool {
        if let drawn = selecting.box {
            selecting.box = nil
            let rect = NSRect(
                x: min(drawn.from.x, drawn.to.x), y: min(drawn.from.y, drawn.to.y),
                width: abs(drawn.to.x - drawn.from.x),
                height: abs(drawn.to.y - drawn.from.y))
            if rect.width < 3, rect.height < 3 {
                selecting.ids = []
                needsDisplay = true
                return false   // a click on empty room moves the time, as before
            }
            selecting.ids = Set(allClips.filter { box($0.clip, lane: $0.lane).intersects(rect) }.map(\.clip.id))
            needsDisplay = true
            return true
        }
        guard let group = selecting.group else { return false }
        selecting.group = nil
        let moves = allClips.filter { selecting.ids.contains($0.clip.id) && !$0.clip.id.isEmpty }.map { item in
            (was: item.clip, now: shown(item.clip, by: group.by))
        }
        if group.by != 0 { onGroup?(moves) }
        needsDisplay = true
        return true
    }

    private func shown(_ clip: Clip, by: Double) -> Clip {
        var moved = clip
        moved.start = max(clip.start + by, 0)
        return moved
    }

    func drawSelecting() {
        guard let drawn = selecting.box else { return }
        let rect = NSRect(
            x: min(drawn.from.x, drawn.to.x), y: min(drawn.from.y, drawn.to.y), width: abs(drawn.to.x - drawn.from.x),
            height: abs(drawn.to.y - drawn.from.y))
        NSColor.fillTint(.controlAccentColor).setFill()
        rect.fill()
        let line = NSBezierPath(rect: rect)
        line.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        line.stroke()
    }

    /// [ and ], Space, ↑ ↓, ↩ and Esc, ⌫ and ⌘C ⌘X on the clips taken. Returns whether the key was one of them.
    func selectKey(_ event: NSEvent) -> Bool {
        let at = self.at
        switch event.charactersIgnoringModifiers {
        case "[": selecting.ids = Set(allClips.filter { $0.clip.start < at }.map(\.clip.id))
        case "]": selecting.ids = Set(allClips.filter { $0.clip.end > at }.map(\.clip.id))
        case " ":
            guard laneDrag == nil, let picked, let lane = tracks.firstIndex(where: { $0.id == picked }) else {
                return false
            }
            laneDrag = (lane, lane)
        default:
            if let drag = laneDrag {
                switch event.keyCode {
                case 126: laneDrag = (drag.from, max(drag.to - 1, 0))   // ↑
                case 125: laneDrag = (drag.from, min(drag.to + 1, tracks.count - 1))   // ↓
                case 36: _ = layerUp()   // ↩
                case 53: laneDrag = nil   // Esc
                default: return false
                }
            } else if selecting.ids.count > 1, [51, 117].contains(event.keyCode) {
                onMany?("remove", Array(selecting.ids))
                selecting.ids = []
            } else {
                return false
            }
        }
        needsDisplay = true
        return true
    }
}
