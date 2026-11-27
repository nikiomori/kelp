import Core
import Foundation
import NIOCore
import PostgresNIO

/// Writes a Postgres value as psql prints it, from the binary form that PostgresNIO receives every result in: numbers
/// with their scale, timestamps in UTC, arrays in braces, bytea as hex. A type it doesn't write (`writes`) is written
/// by the server (`PostgresTexts`).
enum PostgresText {
    static func text(_ cell: PostgresCell) -> String? {
        guard var bytes = cell.bytes else { return nil }
        if cell.format == .text { return bytes.readString(length: bytes.readableBytes) }
        return value(&bytes, type: cell.dataType)
    }

    /// Whether `value` writes this type's values. Any other type's (an enum array, a pgvector, a range) the server
    /// writes with the type's own output function.
    static func writes(_ type: PostgresDataType) -> Bool {
        written.contains(type) || isArray(type) || unaskable.contains(type.rawValue)
    }

    /// The types whose values the server won't take back as a parameter: record, anyarray (pg_stats), cstring, the
    /// planner's statistics and expression trees. `value` writes them as best it can.
    private static let unaskable: Set<UInt32> = [32, 194, 2249, 2275, 2277, 2287, 3361, 3402, 4600, 4601, 5017]

    private static let written: Set<PostgresDataType> = [
        .bool, .int2, .int4, .int8, .oid, .regproc, .xid, .float4, .float8, .numeric, .money, .uuid, .date, .timestamp,
        .timestamptz, .time, .interval, .jsonb, .bytea, .inet, .cidr, .text, .varchar, .bpchar, .char, .name, .json,
        .xml, .unknown, .void
    ]

    static func value(_ byteBuffer: inout ByteBuffer, type: PostgresDataType) -> String {
        switch type {
        case .bool: return byteBuffer.readInteger(as: UInt8.self) == 1 ? "t" : "f"
        case .int2: return byteBuffer.readInteger(as: Int16.self).map(String.init) ?? ""
        case .int4: return byteBuffer.readInteger(as: Int32.self).map(String.init) ?? ""
        case .int8: return byteBuffer.readInteger(as: Int64.self).map(String.init) ?? ""
        case .oid, .regproc, .xid: return byteBuffer.readInteger(as: UInt32.self).map(String.init) ?? ""
        case .float4:
            return byteBuffer.readInteger(as: UInt32.self).map { float(Float(bitPattern: $0), digits: 6) } ?? ""
        case .float8:
            return byteBuffer.readInteger(as: UInt64.self).map { float(Double(bitPattern: $0), digits: 15) } ?? ""
        case .numeric: return numeric(&byteBuffer)
        case .money: return byteBuffer.readInteger(as: Int64.self).map { money($0) } ?? ""
        case .uuid: return uuid(&byteBuffer)
        case .date: return byteBuffer.readInteger(as: Int32.self).map(date) ?? ""
        case .timestamp: return byteBuffer.readInteger(as: Int64.self).map { timestamp($0, zone: false) } ?? ""
        case .timestamptz: return byteBuffer.readInteger(as: Int64.self).map { timestamp($0, zone: true) } ?? ""
        case .time: return byteBuffer.readInteger(as: Int64.self).map(clock) ?? ""
        case .interval: return interval(&byteBuffer)
        case .jsonb:
            byteBuffer.moveReaderIndex(forwardBy: 1)   // jsonb's version byte
            return byteBuffer.readString(length: byteBuffer.readableBytes) ?? ""
        case .bytea: return bytea(&byteBuffer)
        case .inet, .cidr: return inet(&byteBuffer)
        default:
            if isArray(type) || type.rawValue == 2277 {   // anyarray: any array, its element's type inside
                return array(&byteBuffer) ?? "<\(byteBuffer.readableBytes) bytes>"
            }
            return textual(&byteBuffer)
        }
    }

    /// Reads text-like types (text, varchar, name, json, xml) and user-defined types whose binary form is their text.
    private static func textual(_ byteBuffer: inout ByteBuffer) -> String {
        let count = byteBuffer.readableBytes
        guard let bytes = byteBuffer.readBytes(length: count), let text = String(bytes: bytes, encoding: .utf8),
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

    /// Writes a float as Postgres does: the shortest digits that read back as the same value (as Swift's own), and in
    /// exponent form below 1e-4 and from 10^`digits` on (6 for a real, 15 for a double), so a real 0.1 reads 0.1 and
    /// 1234567 reads 1.234567e+06.
    static func float<F: BinaryFloatingPoint & LosslessStringConvertible>(_ value: F, digits: Int) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }
        let parts = value.magnitude.description.split(separator: "e")   // "123.45" or "1.5e-07"
        let whole = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var figures = Array(whole.joined()), point = whole[0].count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while figures.first == "0" {
            figures.removeFirst()
            point -= 1
        }
        while figures.last == "0" { figures.removeLast() }
        let exponent = point - 1
        if exponent < -4 || exponent >= digits {
            let rest = figures.dropFirst().isEmpty ? "" : "." + String(figures.dropFirst())
            return sign + String(figures[0]) + rest + "e" + (exponent < 0 ? "-" : "+")
                + String(format: "%02d", abs(exponent))
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(figures) }
        if point >= figures.count {
            return sign + String(figures) + String(repeating: "0", count: point - figures.count)
        }
        return sign + String(figures[..<point]) + "." + String(figures[point...])
    }

    private static func money(_ cents: Int64) -> String {
        let sign = cents < 0 ? "-" : "", v = cents.magnitude
        return "\(sign)$\(v / 100).\(String(format: "%02d", Int(v % 100)))"
    }

    /// Reads a numeric, which comes as base-10000 digit groups. The first `weight` + 1 groups go before the point,
    /// and `dscale` digits follow it.
    static func numeric(_ byteBuffer: inout ByteBuffer) -> String {
        guard let count = byteBuffer.readInteger(as: Int16.self), let weight = byteBuffer.readInteger(as: Int16.self),
            let sign = byteBuffer.readInteger(as: UInt16.self), let scale = byteBuffer.readInteger(as: Int16.self)
        else { return "" }
        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }
        var digits: [Int16] = []
        for _ in 0..<max(0, Int(count)) { digits.append(byteBuffer.readInteger(as: Int16.self) ?? 0) }
        var whole = ""
        if weight < 0 {
            whole = "0"
        } else {
            for step in 0...Int(weight) {
                let group = step < digits.count ? Int(digits[step]) : 0
                whole += step == 0 ? String(group) : String(format: "%04d", group)
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

    private static func uuid(_ byteBuffer: inout ByteBuffer) -> String {
        guard let bytes = byteBuffer.readBytes(length: 16) else { return "" }
        return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased()
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

    /// Writes the fraction of a second, such as ".5" for 500000 µs, or nothing for zero. Trailing zeros are cut, as
    /// psql does.
    private static func fractionText(_ micros: Int64) -> String {
        guard micros > 0 else { return "" }
        var text = String(format: "%06d", micros)
        while text.hasSuffix("0") { text.removeLast() }
        return "." + text
    }

    private static func interval(_ byteBuffer: inout ByteBuffer) -> String {
        guard let micros = byteBuffer.readInteger(as: Int64.self), let days = byteBuffer.readInteger(as: Int32.self),
            let months = byteBuffer.readInteger(as: Int32.self)
        else { return "" }
        var parts: [String] = []
        let years = months / 12, mons = months % 12
        if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
        if mons != 0 { parts.append("\(mons) mon\(abs(mons) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty { parts.append((micros < 0 ? "-" : "") + clock(abs(micros))) }
        return parts.joined(separator: " ")
    }

    /// The most bytes of a bytea shown. A longer one isn't its own text (`DatabaseRows.opaque`).
    static let byteaShown = 64

    private static func bytea(_ byteBuffer: inout ByteBuffer) -> String {
        let count = byteBuffer.readableBytes
        let shown = byteBuffer.readBytes(length: min(count, byteaShown)) ?? []
        return "\\x" + shown.hex
            + (count > byteaShown ? "… (\(count) bytes)" : "")
    }

    private static func inet(_ byteBuffer: inout ByteBuffer) -> String {
        guard let family = byteBuffer.readInteger(as: UInt8.self), let bits = byteBuffer.readInteger(as: UInt8.self),
            let cidr = byteBuffer.readInteger(as: UInt8.self), let size = byteBuffer.readInteger(as: UInt8.self),
            let addr = byteBuffer.readBytes(length: Int(size))
        else { return "" }
        let text = family == 2 ? addr.map(String.init).joined(separator: ".") : ipv6(addr)
        let full = family == 2 ? 32 : 128
        return cidr == 1 || Int(bits) != full ? "\(text)/\(bits)" : text
    }

    /// An IPv6 address as psql writes it: its longest run of zero groups as `::` (`::1`, `2001:db8::1`).
    private static func ipv6(_ addr: [UInt8]) -> String {
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard addr.count == 16,
            addr.withUnsafeBytes({ inet_ntop(AF_INET6, $0.baseAddress, &out, socklen_t(out.count)) }) != nil
        else { return "" }
        return String(decoding: out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Writes an array as psql does, such as `{1,2,NULL}`, nested for more dimensions. Elements are quoted where psql
    /// would quote them.
    private static func array(_ byteBuffer: inout ByteBuffer) -> String? {
        guard let dims = byteBuffer.readInteger(as: Int32.self), byteBuffer.readInteger(as: Int32.self) != nil,
            let element = byteBuffer.readInteger(as: UInt32.self)
        else { return nil }
        guard dims > 0 else { return "{}" }
        var sizes: [Int] = []
        for _ in 0..<dims {
            guard let size = byteBuffer.readInteger(as: Int32.self), byteBuffer.readInteger(as: Int32.self) != nil
            else { return nil }
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
                guard let length = byteBuffer.readInteger(as: Int32.self), length >= 0,
                    var item = byteBuffer.readSlice(length: Int(length))
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

/// A result's rows as text, as they come. A value `PostgresText` doesn't write is kept as it came, and `finish` has the
/// server write it: the value goes back as a parameter of `SELECT $1::text, …`, and the type's own output function
/// answers, so it reads as psql shows it.
struct PostgresTexts: Sendable {
    var rows = DatabaseRows()
    /// The values the server is to write, by their row and column in `rows`.
    private(set) var asked: [(row: Int, column: Int, value: PostgresData)] = []
    /// The most values asked in one statement, well under the protocol's 65,535 parameters.
    static let perStatement = 1000

    mutating func add(_ cells: [PostgresCell]) {
        let row = rows.rows.count
        var texts: [String?] = [], later: [(row: Int, column: Int, value: PostgresData)] = []
        for cell in cells {
            if cell.dataType == .bytea, cell.bytes?.readableBytes ?? 0 > PostgresText.byteaShown { rows.opaque = true }
            if let bytes = cell.bytes, cell.format == .binary, !PostgresText.writes(cell.dataType) {
                later.append((row, texts.count, PostgresData(type: cell.dataType, value: bytes)))
                texts.append("")
            } else {
                texts.append(PostgresText.text(cell))
            }
        }
        rows.add(columns: cells.map(\.columnName), texts)
        if rows.rows.count > row { asked += later }   // a row past the kept ones isn't asked about
    }

    /// The statements that ask for the text of `asked`, in order, each with its values.
    var questions: [PostgresQuery] {
        stride(from: 0, to: asked.count, by: Self.perStatement).map { start in
            let part = asked[start..<min(start + Self.perStatement, asked.count)]
            var binds = PostgresBindings(capacity: part.count)
            for item in part { binds.append(item.value) }
            let columns = (1...part.count).map { "$\($0)::text" }.joined(separator: ", ")
            return PostgresQuery(unsafeSQL: "SELECT " + columns, binds: binds)
        }
    }

    /// Fills in the values the server writes. `answers` are the questions' rows, one per question.
    mutating func fill(_ answers: [[String?]]) {
        for (item, text) in zip(asked, answers.flatMap { $0 }) {
            rows.rows[item.row][item.column] = text
            rows.bytes += text?.utf8.count ?? 0
        }
        asked = []
    }

    mutating func finish(on conn: PostgresConnection) async throws -> DatabaseRows {
        var answers: [[String?]] = []
        for question in questions {
            for try await row in try await conn.query(question, logger: DatabaseWire.logger) {
                answers.append(row.map(PostgresText.text))
            }
        }
        fill(answers)
        return rows
    }
}

/// ~/.pgpass (or $PGPASSFILE), in libpq's format: one `host:port:database:user:password` per line, with `*` for any
/// value and `\:` and `\\` escaped. It is read for each connection that has no password of its own, as psql does.
enum PgPass {
    /// ~/.pgpass belongs to the user, so it is used for a server they added or one on this Mac. It isn't used for a
    /// host named in a project's files (a cloned repo's .env), because its `*` lines would hand that host the password.
    static func mayUse(for db: DatabaseInfo, host: String) -> Bool { db.source == nil || DatabaseInfo.isLocal(host) }

    static func password(host: String, port: Int, database: String?, user: String) -> String? {
        let path =
            ProcessInfo.processInfo.environment["PGPASSFILE"]
            ?? (NSHomeDirectory() as NSString)
            .appendingPathComponent(".pgpass")
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch { return nil }   // no file is fine
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
        for char in line {
            if escaped {
                field.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == ":" && out.count < 4 {
                out.append(field)
                field = ""
            } else {
                field.append(char)
            }
        }
        out.append(field)
        return out
    }
}
