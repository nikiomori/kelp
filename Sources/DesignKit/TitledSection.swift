import SwiftUI

/// A grouped form's section with its title set as the system sets it (semibold), at Kelp's size. Settings sets its
/// rows' font for the whole window, so a plain `Section("Title")` would take the rows' regular weight.
public struct TitledSection<Content: View>: View {
    private let title: Text
    private let content: Content
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }
    public init(verbatim title: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title)
        self.content = content()
    }
    public var body: some View {
        Section {
            content
        } header: {
            title.font(.ui(TextSize.body, weight: .semibold))
        }
    }
}
