import AppKit
import SwiftUI

/// A segmented choice for SwiftUI, as wide as its labels and never wider than its column, in any language. A segmented
/// Picker makes every segment as wide as the longest label, three times it in all (321 pt in Russian), which gives a
/// bar across the pane that reads as tabs, or one sliding off a 250 pt column. It is regular size, as in Settings and
/// sheets; a tab's or panel's takes `.controlSize(.small)` like any control.
public struct Segments: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int
    @Environment(\.controlSize) private var size

    public init(labels: [String], selection: Binding<Int>) {
        self.labels = labels
        _selection = selection
    }

    public func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels, trackingMode: .selectOne, target: context.coordinator,
            action: #selector(Coordinator.changed))
        control.segmentDistribution = .fillProportionally
        return control
    }
    public func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if (0..<control.segmentCount).map({ control.label(forSegment: $0) ?? "" }) != labels {
            control.segmentCount = labels.count
            for (index, label) in labels.enumerated() { control.setLabel(label, forSegment: index) }
        }
        let small = size == .small || size == .mini
        control.controlSize = small ? .small : .regular
        // A small control keeps its 13 pt words unless told, as in `Bar`. SwiftUI may have made it small already.
        let font = NSFont.ui(TextSize.caption)
        if small, control.font?.pointSize != font.pointSize { control.font = font }
        control.selectedSegment = selection
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context)
        -> CGSize?
    {
        CGSize(
            width: min(proposal.width ?? .infinity, control.intrinsicContentSize.width),
            height: control.intrinsicContentSize.height
        )
    }
    public func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor public final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ control: NSSegmentedControl) { selection.wrappedValue = control.selectedSegment }
    }
}
