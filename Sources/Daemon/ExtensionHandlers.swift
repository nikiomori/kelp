import Core
import Foundation

extension Methods {
    static let extensionMethods: [any Handled.Type] = [ExtensionLibrary.self, ExtensionFetch.self]
}

extension ExtensionLibrary: Handled {
    func handle(_ settings: SettingsStore) throws -> Result {
        try IDE.library(index: settings["extensions.library"]?.string ?? IDE.libraryIndex)
    }
}

extension ExtensionFetch: Handled {
    func handle(_: NoService) throws -> Result { Result(folder: try IDE.fetchExtension(source, files: files).path) }
}
