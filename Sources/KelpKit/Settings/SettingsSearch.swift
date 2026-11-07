import Foundation

/// What Settings' search finds: rows by the words on them and on their group and section, each group once, and the
/// sections drawn by hand (Integrations, Agent Catalog…) by the words they declare.
struct SettingsSearch: Identifiable {
    let section: SettingsSection
    let group: String?
    var specs: [SettingSpec]
    /// Declared words that matched: a row each, with Open.
    var screens: [String] = []

    var id: String { section.id + "/" + (group ?? "") }
    /// "Agents › Notifications": a row can say little without its group.
    var title: String { group.map { "\(loc(section.title)) › \(loc($0))" } ?? loc(section.title) }

    static func find(_ query: String, in sections: [SettingsSection]) -> [SettingsSearch] {
        let needle = query.lowercased()
        // In English and as shown (a Russian search finds Russian titles).
        func hit(_ words: String...) -> Bool { words.contains { ($0 + " " + loc($0)).lowercased().contains(needle) } }
        return sections.flatMap { section -> [SettingsSearch] in
            var found = section.groups.compactMap { group, specs -> SettingsSearch? in
                let rows = specs.filter {
                    hit($0.title, $0.key, $0.description ?? "", $0.help ?? "", group ?? "", section.title)
                }
                return rows.isEmpty ? nil : SettingsSearch(section: section, group: group, specs: rows)
            }
            var screens = section.keywords.filter { hit($0) }
            if screens.isEmpty, section.specs.isEmpty, hit(section.title) { screens = [section.title] }
            if !screens.isEmpty {
                found.append(SettingsSearch(section: section, group: nil, specs: [], screens: screens.map(loc)))
            }
            return found
        }
    }
}
