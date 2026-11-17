import Foundation

/// How long ago, as short as a row allows: "now", "4m", "2h", "3d".
public func shortAgo(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let elapsed = now.timeIntervalSince(date)
    return elapsed < 60 ? String(localized: "now") : shortSpan(elapsed)
}

/// A span in Kelp's language, with `units` parts at most (the last one rounded), down to `smallest`: "4m", "1d 3h".
/// One formatter per kind is kept, because every row on every sidebar pass and every clock tick made a new one.
public func shortSpan(_ seconds: Double, units: Int = 1, smallest: NSCalendar.Unit = .minute) -> String {
    let language = Bundle.main.preferredLocalizations.first ?? "en",
        key = "\(units) \(smallest.rawValue) \(language)" as NSString
    let formatter =
        spanFormatters.object(forKey: key)
        ?? {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = units
            formatter.allowedUnits = [.day, .hour, .minute, smallest]
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: language)
            formatter.calendar = calendar
            spanFormatters.setObject(formatter, forKey: key)
            return formatter
        }()
    return formatter.string(from: max(0, seconds)) ?? ""
}
// NSCache is thread-safe, and so is formatting.
nonisolated(unsafe) private let spanFormatters = NSCache<NSString, DateComponentsFormatter>()

/// Tokens as the context card says them: 17_600 → "17.6k", 31_000 → "31k", 184_000 → "184k", 640 → "640".
public func shortTokens(_ tokens: Int) -> String {
    guard tokens >= 1000 else { return "\(tokens)" }
    let tenths = (tokens + 50) / 100
    return tokens >= 100_000 || tenths % 10 == 0 ? "\((tokens + 500) / 1000)k" : "\(tenths / 10).\(tenths % 10)k"
}

/// Bytes as people read memory and disk: "870 MB", "3.1 GB".
public func bytes(_ n: Int) -> String { bytes(n, file: false) }
/// With `file`, a file's size as Finder shows it (by 1000, not 1024).
public func bytes(_ count: Int, file: Bool) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: file ? .file : .memory)
}
