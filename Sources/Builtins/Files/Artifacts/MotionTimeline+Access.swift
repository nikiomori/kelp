import AppKit

/// The timeline as VoiceOver reads it: a group of its clips and marks, each named with its lane and its time
/// ("Вступление, scene, 0 to 2 seconds"), at its place on screen.
extension MotionTimeline {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Timeline") }

    override func accessibilityChildren() -> [Any]? {
        let seconds = { (value: Double) in String(format: "%.1f", value) }
        var out: [NSAccessibilityElement] = []
        func add(_ label: String, _ rect: NSRect) {
            let element = NSAccessibilityElement.element(
                withRole: .button, frame: NSAccessibility.screenRect(fromView: self, rect: rect), label: label,
                parent: self)
            if let element = element as? NSAccessibilityElement { out.append(element) }
        }
        for scene in scenes {
            add(
                String(localized: "\(scene.title), scene, \(seconds(scene.start)) to \(seconds(scene.end)) seconds"),
                box(scene, lane: 0))
        }
        for (i, track) in tracks.enumerated() {
            let hidden = track.hidden ? String(localized: ", hidden") : ""
            add(
                String(localized: "\(track.title)\(hidden), \(seconds(track.start)) to \(seconds(track.end)) seconds"),
                box(track, lane: i + 1))
        }
        for mark in marks {
            add(String(localized: "Mark \(mark.id), at \(seconds(mark.time)) seconds"), diamond(mark))
        }
        return out
    }
}
