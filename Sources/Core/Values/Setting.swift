/// A setting: its key in settings.json and the value it has while the file doesn't set it. Each setting is declared
/// once (`SettingKeys`), and the app, the daemon and the CLI all read it through that declaration.
public struct Setting<Value: SettingValue>: Sendable {
    public let key: String
    public let fallback: Value

    public init(_ key: String, _ fallback: Value) {
        self.key = key
        self.fallback = fallback
    }

    /// Reads a value from settings.json as this setting's type. It returns the fallback when there is no value, or when
    /// the value is of another type.
    public func read(_ stored: JSONValue?) -> Value { stored.flatMap(Value.init(setting:)) ?? fallback }
    /// Returns the setting's value in `settings` (the answer of `settings.get`).
    public func read(in settings: [String: JSONValue]) -> Value { read(settings[key]) }
}

/// A type a setting can hold, read from and written to settings.json.
public protocol SettingValue: Sendable {
    /// Returns nil when the stored value is of another type.
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

/// An int or a double in settings.json. A whole number is written as an int, the way people type it.
extension Double: SettingValue {
    public init?(setting: JSONValue) {
        guard let value = setting.number else { return nil }
        self = value
    }
    public var setting: JSONValue? { rounded() == self && abs(self) < 1e15 ? .int(Int(self)) : .double(self) }
}

/// An array keeps the elements of the right type and leaves the others out.
extension Array: SettingValue where Element: SettingValue {
    public init?(setting: JSONValue) {
        guard let values = setting.array else { return nil }
        self = values.compactMap(Element.init(setting:))
    }
    public var setting: JSONValue? { .array(compactMap(\.setting)) }
}

/// For a setting whose absence has its own meaning.
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
