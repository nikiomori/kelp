import Foundation

/// Reads JSON as editors and some tools write it, with comments and trailing commas (JSON5, the way package.json is
/// read).
enum JSONC {
    static func object(_ text: String) -> [String: Any]? { value(text) as? [String: Any] }

    static func value(_ text: String) -> Any? {
        Log.session.attempt("reading another tool's project file") {
            try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed)
        }
    }
}
