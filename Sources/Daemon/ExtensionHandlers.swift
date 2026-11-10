import Core
import Foundation

extension Methods {
    static let extensionMethods: [any Handled.Type] = [ExtensionLibrary.self, ExtensionFetch.self]
}

extension ExtensionLibrary: Handled {
    func handle(_ settings: SettingsStore) throws -> Result {
        try ExtensionFiles.library(index: settings[SettingKeys.extensionLibrary])
    }
}

extension ExtensionFetch: Handled {
    func handle(_: NoService) throws -> Result {
        Result(folder: try ExtensionFiles.fetchExtension(source, files: files).path)
    }
}
