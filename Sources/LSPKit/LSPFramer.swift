import Foundation

/// `Content-Length` framed JSON-RPC, as LSP speaks over stdio.
public struct LSPFramer: Sendable {
    private var buf = Data()
    static let maxBody = 256 << 20
    public init() {}
    public static func frame(_ body: Data) -> Data { Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body }
    public mutating func append(_ chunk: Data) -> [Data] {
        buf.append(chunk)
        var out: [Data] = []
        let sep = Data("\r\n\r\n".utf8)
        while let headerEnd = buf.range(of: sep) {
            let header = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            // A missing, negative or absurd length is a broken header: skip it rather than trap or wait forever.
            guard
                let len = header.split(separator: "\r\n").compactMap({ line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    return parts.count == 2 && parts[0].lowercased() == "content-length"
                        ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                }).first, (0...Self.maxBody).contains(len)
            else {
                buf.removeSubrange(buf.startIndex..<headerEnd.upperBound)
                continue
            }
            guard buf.distance(from: headerEnd.upperBound, to: buf.endIndex) >= len else { break }
            let end = buf.index(headerEnd.upperBound, offsetBy: len)
            out.append(Data(buf[headerEnd.upperBound..<end]))
            buf.removeSubrange(buf.startIndex..<end)
        }
        return out
    }
}
