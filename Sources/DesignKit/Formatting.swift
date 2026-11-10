import Foundation

/// "now", "4m", "2h", "3d": how long ago, as short as a row allows.
public func shortAgo(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let elapsed = now.timeIntervalSince(date)
    return elapsed < 60 ? String(localized: "now") : shortSpan(elapsed)
}

/// "4m", "1d 3h": a span in Kelp's language, `units` parts at most (the last one rounded), down to `smallest`.
/// One formatter per kind, kept: every row on every sidebar pass and every clock tick made a new one.
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
nonisolated(unsafe) private let spanFormatters = NSCache<NSString, DateComponentsFormatter>()   // NSCache is thread-safe, as is formatting

/// Bytes as people read memory and disk: "870 MB", "3.1 GB".
public func bytes(_ n: Int) -> String { bytes(n, file: false) }
/// `file`: a file's size, as Finder shows it (by 1000, not 1024).
public func bytes(_ n: Int, file: Bool) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: file ? .file : .memory)
}
