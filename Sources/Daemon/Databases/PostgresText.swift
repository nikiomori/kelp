import Core
import Foundation
import NIOCore
import PostgresNIO

/// A Postgres value as psql prints it, from the binary form PostgresNIO receives every result in: numbers with their
/// scale, timestamps in UTC, arrays in braces, bytea as hex. A type it doesn't know shows its text when that's what
/// its bytes are (enums, citext, domains over text), else its size.
enum PostgresText {
    static func text(_ cell: PostgresCell) -> String? {
        guard var bytes = cell.bytes else { return nil }
        if cell.format == .text { return bytes.readString(length: bytes.readableBytes) }
        return value(&bytes, type: cell.dataType)
    }

    // ponytail: the common built-in types; geometric, range and full-text values fall back to their size
    static func value(_ b: inout ByteBuffer, type: PostgresDataType) -> String {
        switch type {
        case .bool: return b.readInteger(as: UInt8.self) == 1 ? "t" : "f"
        case .int2: return b.readInteger(as: Int16.self).map(String.init) ?? ""
        case .int4: return b.readInteger(as: Int32.self).map(String.init) ?? ""
        case .int8: return b.readInteger(as: Int64.self).map(String.init) ?? ""
        case .oid, .regproc, .xid: return b.readInteger(as: UInt32.self).map(String.init) ?? ""
        case .float4: return b.readInteger(as: UInt32.self).map { float(Double(Float(bitPattern: $0))) } ?? ""
        case .float8: return b.readInteger(as: UInt64.self).map { float(Double(bitPattern: $0)) } ?? ""
        case .numeric: return numeric(&b)
        case .money: return b.readInteger(as: Int64.self).map { money($0) } ?? ""
        case .uuid: return uuid(&b)
        case .date: return b.readInteger(as: Int32.self).map(date) ?? ""
        case .timestamp: return b.readInteger(as: Int64.self).map { timestamp($0, zone: false) } ?? ""
        case .timestamptz: return b.readInteger(as: Int64.self).map { timestamp($0, zone: true) } ?? ""
        case .time: return b.readInteger(as: Int64.self).map(clock) ?? ""
        case .interval: return interval(&b)
        case .jsonb:
            b.moveReaderIndex(forwardBy: 1)   // jsonb's version byte
            return b.readString(length: b.readableBytes) ?? ""
        case .bytea: return bytea(&b)
        case .inet, .cidr: return inet(&b)
        default:
            if type.knownSQLName?.hasPrefix("_") == true || type.rawValue == 1000 || isArray(type) {
                return array(&b) ?? "<\(b.readableBytes) bytes>"
            }
            return textual(&b)
        }
    }

    /// Text-like types (text, varchar, name, json, xml) and user ones whose binary form is their text.
    private static func textual(_ b: inout ByteBuffer) -> String {
        let count = b.readableBytes
        guard let bytes = b.readBytes(length: count), let text = String(bytes: bytes, encoding: .utf8),
            !text.unicodeScalars.contains(where: { $0.value < 32 && !["\n", "\r", "\t"].contains($0) })
        else { return "<\(count) bytes>" }
        return text
    }

    private static func isArray(_ type: PostgresDataType) -> Bool {
        [
            PostgresDataType.boolArray, .int2Array, .int4Array, .int8Array, .float4Array, .float8Array, .textArray,
            .varcharArray, .uuidArray, .jsonbArray, .numericArray, .dateArray, .timestamptzArray
        ].contains(type)
    }

    static func float(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }

    private static func money(_ cents: Int64) -> String {
        let sign = cents < 0 ? "-" : "", v = cents.magnitude
        return "\(sign)$\(v / 100).\(String(format: "%02d", Int(v % 100)))"
    }

    /// Base-10000 digits, the first `weight` + 1 before the point, `dscale` digits after it.
    static func numeric(_ b: inout ByteBuffer) -> String {
        guard let count = b.readInteger(as: Int16.self), let weight = b.readInteger(as: Int16.self),
            let sign = b.readInteger(as: UInt16.self), let scale = b.readInteger(as: Int16.self)
        else { return "" }
        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }
        var digits: [Int16] = []
        for _ in 0..<max(0, Int(count)) { digits.append(b.readInteger(as: Int16.self) ?? 0) }
        var whole = ""
        if weight < 0 {
            whole = "0"
        } else {
            for i in 0...Int(weight) {
                let group = i < digits.count ? Int(digits[i]) : 0
                whole += i == 0 ? String(group) : String(format: "%04d", group)
            }
        }
        var fraction = ""
        var index = Int(weight) + 1
        while fraction.count < Int(scale) {
            let group = index >= 0 && index < digits.count ? Int(digits[index]) : 0
            fraction += String(format: "%04d", group)
            index += 1
        }
        let text = whole + (scale > 0 ? "." + fraction.prefix(Int(scale)) : "")
        return (sign == 0x4000 && text.contains(where: { $0 != "0" && $0 != "." }) ? "-" : "") + text
    }

    private static func uuid(_ b: inout ByteBuffer) -> String {
        guard let bytes = b.readBytes(length: 16) else { return "" }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(
                hex[
                    hex.index(
                        hex.startIndex, offsetBy: range.lowerBound)..<hex.index(
                            hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }

    /// Postgres counts from 2000-01-01.
    private static var epoch: Date { Date(timeIntervalSince1970: 946_684_800) }
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
    private static let day = formatter("yyyy-MM-dd")
    private static let moment = formatter("yyyy-MM-dd HH:mm:ss")

    private static func date(_ days: Int32) -> String {
        if days == .max { return "infinity" }
        if days == .min { return "-infinity" }
        return day.string(from: epoch.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    private static func timestamp(_ micros: Int64, zone: Bool) -> String {
        if micros == .max { return "infinity" }
        if micros == .min { return "-infinity" }
        let seconds = micros >= 0 ? micros / 1_000_000 : (micros - 999_999) / 1_000_000
        let rest = micros - seconds * 1_000_000
        let text = moment.string(from: epoch.addingTimeInterval(TimeInterval(seconds)))
        return text + fractionText(rest) + (zone ? "+00" : "")
    }

    private static func clock(_ micros: Int64) -> String {
        let seconds = micros / 1_000_000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            + fractionText(micros % 1_000_000)
    }

    /// ".5" for 500000 µs, nothing for none: trailing zeros cut, as psql does.
    private static func fractionText(_ micros: Int64) -> String {
        guard micros > 0 else { return "" }
        var text = String(format: "%06d", micros)
        while text.hasSuffix("0") { text.removeLast() }
        return "." + text
    }

    private static func interval(_ b: inout ByteBuffer) -> String {
        guard let micros = b.readInteger(as: Int64.self), let days = b.readInteger(as: Int32.self),
            let months = b.readInteger(as: Int32.self)
        else { return "" }
        var parts: [String] = []
        let years = months / 12, mons = months % 12
        if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
        if mons != 0 { parts.append("\(mons) mon\(abs(mons) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty { parts.append((micros < 0 ? "-" : "") + clock(abs(micros))) }
        return parts.joined(separator: " ")
    }

    private static func bytea(_ b: inout ByteBuffer) -> String {
        let count = b.readableBytes
        let shown = b.readBytes(length: min(count, 64)) ?? []
        return "\\x" + shown.map { String(format: "%02x", $0) }.joined() + (count > 64 ? "… (\(count) bytes)" : "")
    }

    private static func inet(_ b: inout ByteBuffer) -> String {
        guard let family = b.readInteger(as: UInt8.self), let bits = b.readInteger(as: UInt8.self),
            let cidr = b.readInteger(as: UInt8.self), let size = b.readInteger(as: UInt8.self),
            let addr = b.readBytes(length: Int(size))
        else { return "" }
        let text =
            family == 2
            ? addr.map(String.init).joined(separator: ".")
            : stride(from: 0, to: addr.count, by: 2).map {
                String(UInt16(addr[$0]) << 8 | UInt16(addr[$0 + 1]), radix: 16)
            }.joined(separator: ":")
        let full = family == 2 ? 32 : 128
        return cidr == 1 || Int(bits) != full ? "\(text)/\(bits)" : text
    }

    /// `{1,2,NULL}`, nested for more dimensions; elements quoted when psql would.
    private static func array(_ b: inout ByteBuffer) -> String? {
        guard let dims = b.readInteger(as: Int32.self), b.readInteger(as: Int32.self) != nil,
            let element = b.readInteger(as: UInt32.self)
        else { return nil }
        guard dims > 0 else { return "{}" }
        var sizes: [Int] = []
        for _ in 0..<dims {
            guard let size = b.readInteger(as: Int32.self), b.readInteger(as: Int32.self) != nil else { return nil }
            sizes.append(Int(size))
        }
        let type = PostgresDataType(element)
        func level(_ depth: Int) -> String {
            var items: [String] = []
            for _ in 0..<sizes[depth] {
                if depth + 1 < sizes.count {
                    items.append(level(depth + 1))
                    continue
                }
                guard let length = b.readInteger(as: Int32.self), length >= 0,
                    var item = b.readSlice(length: Int(length))
                else {
                    items.append("NULL")
                    continue
                }
                let text = value(&item, type: type)
                let plain =
                    !text.isEmpty && text.uppercased() != "NULL"
                    && !text.contains(where: { ",{}\"\\ ".contains($0) })
                items.append(
                    plain
                        ? text
                        : "\""
                            + text.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"") + "\"")
            }
            return "{" + items.joined(separator: ",") + "}"
        }
        return level(0)
    }
}

/// ~/.pgpass (or $PGPASSFILE), libpq's: `host:port:database:user:password` a line, `*` for any, `\:` and `\\`
/// escaped. Read for each connection that has no password of its own, as psql does.
enum PgPass {
    /// ~/.pgpass is the user's: for a server they added, or one on this Mac; not for a host a project's files name (a
    /// cloned repo's .env), which its `*` lines would hand the password to.
    static func mayUse(for db: DatabaseInfo, host: String) -> Bool { db.source == nil || DatabaseInfo.isLocal(host) }

    static func password(host: String, port: Int, database: String?, user: String) -> String? {
        let path =
            ProcessInfo.processInfo.environment["PGPASSFILE"]
            ?? (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pgpass")
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch { return nil }   // none: fine
        return match(text, host: host, port: port, database: database ?? user, user: user)
    }

    static func match(_ text: String, host: String, port: Int, database: String, user: String) -> String? {
        let hosts = DatabaseInfo.isLocal(host) ? [host, "localhost", "127.0.0.1"] : [host]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let entry = fields(String(line))
            guard entry.count == 5 else { continue }
            func fits(_ field: String, _ values: [String]) -> Bool { field == "*" || values.contains(field) }
            if fits(entry[0], hosts), fits(entry[1], [String(port)]), fits(entry[2], [database]), fits(entry[3], [user])
            {
                return entry[4]
            }
        }
        return nil
    }

    static func fields(_ line: String) -> [String] {
        var out: [String] = [], field = "", escaped = false
        for c in line {
            if escaped {
                field.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == ":" && out.count < 4 {
                out.append(field)
                field = ""
            } else {
                field.append(c)
            }
        }
        out.append(field)
        return out
    }
}
