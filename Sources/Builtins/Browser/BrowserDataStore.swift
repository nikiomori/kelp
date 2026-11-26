import Foundation
import WebKit

@MainActor
final class BrowserDataStores {
    // Keep the WebKit session alive between tabs while it writes its data to disk.
    private var stores: [UUID: WKWebsiteDataStore] = [:]

    func store(owner: String?) -> WKWebsiteDataStore {
        guard let owner, let identifier = UUID(uuidString: owner), identifier.uuid.6 >> 4 == 4 else {
            return .nonPersistent()
        }
        if let store = stores[identifier] { return store }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        stores[identifier] = store
        return store
    }
}
