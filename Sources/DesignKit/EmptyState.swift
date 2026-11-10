import SwiftUI

/// `EmptyStateView` for a SwiftUI page: the same block (a 28 pt icon at the chrome's weight, a semibold title, a line
/// of what to do, a button or two), lifted over the middle as it is there. SwiftUI's own `ContentUnavailableView` draws
/// a bigger icon and title, so a SwiftUI tab's empty state read as another app's beside a panel's.
/// `lifted: false`: the block alone, for one that sits over other content instead of filling the page.
public struct EmptyState<Description: View, Actions: View>: View {
    private let title: String
    private let symbol: String
    private let lifted: Bool
    private let description: Description
    private let actions: Actions

    public init(
        _ title: String, symbol: String, lifted: Bool = true, @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.symbol = symbol
        self.lifted = lifted
        self.description = description()
        self.actions = actions()
    }

    public var body: some View {
        let block = VStack(spacing: Metrics.gapWide) {
            Image(systemName: symbol).font(.symbol(Metrics.iconEmpty)).foregroundStyle(.tertiary)
            VStack(spacing: Metrics.gap) {
                Text(title).font(.ui(TextSize.body, weight: .semibold))
                description.font(.ui(TextSize.body)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: Metrics.gapWide) { actions }
        }
        .padding(.horizontal, Metrics.inset + 4)
        if lifted {
            block.offset(y: -Metrics.emptyLift).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            block.frame(maxWidth: .infinity)
        }
    }
}

extension EmptyState where Actions == EmptyView {
    public init(_ title: String, symbol: String, lifted: Bool = true, @ViewBuilder description: () -> Description) {
        self.init(title, symbol: symbol, lifted: lifted, description: description) { EmptyView() }
    }
}
extension EmptyState where Description == EmptyView, Actions == EmptyView {
    public init(_ title: String, symbol: String, lifted: Bool = true) {
        self.init(title, symbol: symbol, lifted: lifted) { EmptyView() }
    }
}
