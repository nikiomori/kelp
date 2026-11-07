/// A setting: its key in settings.json and its value while the file doesn't say, declared once (`SettingKeys`) and read
/// by that declaration in the app, the daemon and the CLI.
public struct Setting<Value: SettingValue>: Sendable {
    public let key: String
    public let fallback: Value

    public init(_ key: String, _ fallback: Value) {
        self.key = key
        self.fallback = fallback
    }

    /// A value from settings.json as this setting's type: the fallback when there's none, or one of another type.
    public func read(_ stored: JSONValue?) -> Value { stored.flatMap(Value.init(setting:)) ?? fallback }
    /// Its value in these settings (`settings.get`'s answer).
    public func read(in settings: [String: JSONValue]) -> Value { read(settings[key]) }
}

/// What a setting holds, from and to settings.json.
public protocol SettingValue: Sendable {
    /// nil: the stored value is of another type.
    init?(setting: JSONValue)
    var setting: JSONValue? { get }
}

extension Bool: SettingValue {
    public init?(setting: JSONValue) {
        guard let value = setting.bool else { return nil }
        self = value
    }
    public var setting: JSONValue? { .bool(self) }
}

extension String: SettingValue {
    public init?(setting: JSONValue) {
        guard let value = setting.string else { return nil }
        self = value
    }
    public var setting: JSONValue? { .string(self) }
}

/// An int or a double in settings.json; a whole number is written as an int, as people type it.
extension Double: SettingValue {
    public init?(setting: JSONValue) {
        guard let value = setting.number else { return nil }
        self = value
    }
    public var setting: JSONValue? { rounded() == self && abs(self) < 1e15 ? .int(Int(self)) : .double(self) }
}

/// Its elements of the right type; the others are left out.
extension Array: SettingValue where Element: SettingValue {
    public init?(setting: JSONValue) {
        guard let values = setting.array else { return nil }
        self = values.compactMap(Element.init(setting:))
    }
    public var setting: JSONValue? { .array(compactMap(\.setting)) }
}

/// For a setting whose absence means something of its own.
extension Optional: SettingValue where Wrapped: SettingValue {
    public init?(setting: JSONValue) {
        guard let value = Wrapped(setting: setting) else { return nil }
        self = value
    }
    public var setting: JSONValue? { self?.setting }
}

extension JSONValue: SettingValue {
    public init?(setting: JSONValue) { self = setting }
    public var setting: JSONValue? { self }
}
