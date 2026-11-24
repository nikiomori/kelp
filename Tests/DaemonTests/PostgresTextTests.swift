import Foundation
import MySQLNIO
import NIOCore
import PostgresNIO
import Testing

@testable import Daemon

/// A value's binary form as Postgres sends it, built from big-endian integers and raw bytes.
private enum Part {
    case i16(Int16), u16(UInt16), i32(Int32), u32(UInt32), i64(Int64), u8(UInt8), bytes([UInt8])
}

private func buffer(_ parts: [Part]) -> ByteBuffer {
    var buffer = ByteBuffer()
    for part in parts {
        switch part {
        case .i16(let v): buffer.writeInteger(v)
        case .u16(let v): buffer.writeInteger(v)
        case .i32(let v): buffer.writeInteger(v)
        case .u32(let v): buffer.writeInteger(v)
        case .i64(let v): buffer.writeInteger(v)
        case .u8(let v): buffer.writeInteger(v)
        case .bytes(let v): buffer.writeBytes(v)
        }
    }
    return buffer
}

/// A numeric: its base-10000 groups, the weight of the first, its sign and its scale.
private func numeric(_ groups: [Int16], weight: Int16, negative: Bool = false, scale: Int16) -> [Part] {
    [.i16(Int16(groups.count)), .i16(weight), .u16(negative ? 0x4000 : 0), .i16(scale)] + groups.map { .i16($0) }
}

/// A one-dimensional array of `element` values (nil: NULL), each with its length first.
private func array(_ element: UInt32, _ items: [[UInt8]?]) -> [Part] {
    [.i32(1), .i32(items.contains(nil) ? 1 : 0), .u32(element), .i32(Int32(items.count)), .i32(1)]
        + items.flatMap { item -> [Part] in item.map { [.i32(Int32($0.count)), .bytes($0)] } ?? [.i32(-1)] }
}

/// Each type's binary form is written as psql writes it (DatabaseLiveTests checks the same against a server).
@Test func postgresValuesReadAsPsqlWritesThem() {
    let micros: Int64 = 847_511_509_000_000   // 2026-11-09 03:51:49 UTC, counted from 2000-01-01
    let rows: [(PostgresDataType, [Part], String)] = [
        (.numeric, numeric([42, 5000], weight: 0, scale: 2), "42.50"),
        (.numeric, numeric([123, 4567, 5000], weight: 1, scale: 1), "1234567.5"),
        (.numeric, numeric([1, 2300], weight: -1, negative: true, scale: 6), "-0.000123"),
        (.numeric, numeric([123], weight: -2, scale: 8), "0.00000123"),   // a group of zeros before the first
        (.numeric, numeric([], weight: 0, negative: true, scale: 2), "0.00"),   // no "-0.00"
        (.numeric, [.i16(0), .i16(0), .u16(0xC000), .i16(0)], "NaN"),
        (.interval, [.i64(14_706_000_000), .i32(3), .i32(14)], "1 year 2 mons 3 days 04:05:06"),
        (.interval, [.i64(-3_600_000_000), .i32(0), .i32(0)], "-01:00:00"),
        (.interval, [.i64(0), .i32(0), .i32(0)], "00:00:00"),
        (.timestamptz, [.i64(micros)], "2026-11-09 03:51:49+00"),
        (.timestamp, [.i64(micros + 120_000)], "2026-11-09 03:51:49.12"),
        (.timestamptz, [.i64(-500_000)], "1999-12-31 23:59:59.5+00"),   // before 2000, the second rounds down
        (.int4Array, array(23, [[0, 0, 0, 1], [0, 0, 0, 2], nil]), "{1,2,NULL}"),
        (.textArray, array(25, [Array("a b".utf8), Array("c".utf8), Array("NULL".utf8)]), #"{"a b",c,"NULL"}"#),
        (.inet, [.u8(2), .u8(24), .u8(0), .u8(4), .bytes([192, 168, 0, 1])], "192.168.0.1/24"),
        (.inet, [.u8(2), .u8(32), .u8(0), .u8(4), .bytes([10, 0, 0, 1])], "10.0.0.1"),
        (.cidr, [.u8(2), .u8(32), .u8(1), .u8(4), .bytes([10, 0, 0, 1])], "10.0.0.1/32"),
        (.inet, [.u8(3), .u8(128), .u8(0), .u8(16), .bytes(Array(repeating: 0, count: 15) + [1])], "::1"),
        (
            .inet,
            [.u8(3), .u8(64), .u8(0), .u8(16), .bytes([0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1])],
            "2001:db8::1/64"
        ),
        (.float4, [.u32(Float(0.1).bitPattern)], "0.1"),   // the real, not the double nearest it
        (.float4, [.u32(Float(1_234_567).bitPattern)], "1.234567e+06"),
        (.float4, [.u32(Float(0.0001).bitPattern)], "0.0001"),
        (.float8, [.i64(Int64(bitPattern: (1e15).bitPattern))], "1e+15"),
        (.float8, [.i64(Int64(bitPattern: (123_456_789_012_345.6).bitPattern))], "123456789012345.6"),
        (.float8, [.i64(Int64(bitPattern: (-1.5e-7).bitPattern))], "-1.5e-07"),
        (.float8, [.i64(Int64(bitPattern: (100.0).bitPattern))], "100"),
        (.money, [.i64(1234)], "$12.34"),
        (.money, [.i64(-5)], "-$0.05"),
        (.bytea, [.bytes([0xDE, 0xAD, 0xBE, 0xEF])], "\\xdeadbeef"),
        (
            .bytea, [.bytes(Array(repeating: 0xAB, count: 65))],
            "\\x" + String(repeating: "ab", count: 64) + "… (65 bytes)"
        )
    ]
    for (type, parts, expected) in rows {
        var bytes = buffer(parts)
        #expect(PostgresText.value(&bytes, type: type) == expected, "\(type) \(expected)")
    }
}

/// A value of a type Kelp doesn't write (an enum array) goes back to the server, which writes it; one of a row past the
/// kept ones isn't asked about, and a bytea longer than is shown makes the rows not their own text.
@Test func postgresAsksTheServerForTypesItDoesntWrite() {
    func cell(_ type: PostgresDataType, _ bytes: [UInt8], _ column: Int) -> PostgresCell {
        PostgresCell(
            bytes: ByteBuffer(bytes: bytes), dataType: type, format: .binary, columnName: "c\(column)",
            columnIndex: column)
    }
    let enumArray = PostgresDataType(16_400)
    var texts = PostgresTexts()
    texts.add([cell(.int4, [0, 0, 0, 7], 0), cell(enumArray, [0, 0, 0, 1, 0, 0, 0, 0], 1)])
    #expect(texts.rows.rows == [["7", ""]] && texts.asked.count == 1)
    #expect(texts.questions.map(\.sql) == ["SELECT $1::text"])
    texts.fill([["{paid,new}"]])
    #expect(texts.rows.rows == [["7", "{paid,new}"]] && texts.asked.isEmpty && !texts.rows.opaque)
    texts.add([cell(.bytea, Array(repeating: 1, count: 65), 0), cell(enumArray, [1], 1)])
    #expect(texts.rows.opaque && texts.asked.count == 1)
    texts.rows.rows = Array(repeating: [], count: DatabaseEngines.keep)
    texts.add([cell(enumArray, [1], 0)])
    #expect(texts.asked.count == 1)   // the row isn't kept, so neither is its question
}

/// MySQL's bytes (a BINARY(16) key, a BLOB, a BIT) show as hex, as SQL writes them back; a number, which comes in the
/// binary character set too, and text show as they come.
@Test func mySQLBytesShowAsHex() {
    #expect(MySQLWire.binary(.binary, .string) && MySQLWire.binary(.binary, .blob) && MySQLWire.binary(.binary, .bit))
    #expect(!MySQLWire.binary(.binary, .long) && !MySQLWire.binary(.utf8mb4, .varString))
    #expect(MySQLWire.text(ByteBuffer(bytes: [0x00, 0xDE, 0xAD]), binary: true) == "0x00dead")
    #expect(MySQLWire.text(ByteBuffer(string: "abc"), binary: false) == "abc")
    let long = MySQLWire.text(ByteBuffer(bytes: Array(repeating: 0xAB, count: 65)), binary: true)
    #expect(long.hasSuffix("… (65 bytes)"))
}
