import Compression
import Foundation

/// Minimal ZIP writer for the package formats Grapefruit produces (EPUB, XLSX, PPTX, ODS).
final class ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let method: UInt16
        let compressedSize: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []
    private let time: UInt16
    private let date: UInt16

    init() {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    func add(_ path: String, _ data: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var payload = data
        var method: UInt16 = 0
        if compress, data.count > 64, let deflated = Deflate.compress(data), deflated.count < data.count {
            payload = deflated
            method = 8
        }
        let offset = UInt32(body.count)
        body.appendLE(UInt32(0x04034b50))
        body.appendLE(UInt16(20))          // version needed
        body.appendLE(UInt16(0x0800))      // UTF-8 names
        body.appendLE(method)
        body.appendLE(time)
        body.appendLE(date)
        body.appendLE(crc)
        body.appendLE(UInt32(payload.count))
        body.appendLE(UInt32(data.count))
        body.appendLE(UInt16(name.count))
        body.appendLE(UInt16(0))
        body.append(name)
        body.append(payload)
        entries.append(Entry(name: name, crc: crc, method: method, compressedSize: UInt32(payload.count),
                             size: UInt32(data.count), offset: offset))
    }

    func add(_ path: String, _ text: String, compress: Bool = true) {
        add(path, Data(text.utf8), compress: compress)
    }

    func finish() -> Data {
        var out = body
        let directoryStart = UInt32(out.count)
        for e in entries {
            out.appendLE(UInt32(0x02014b50))
            out.appendLE(UInt16(0x031E))       // made by: Unix, 3.0
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(0x0800))
            out.appendLE(e.method)
            out.appendLE(time)
            out.appendLE(date)
            out.appendLE(e.crc)
            out.appendLE(e.compressedSize)
            out.appendLE(e.size)
            out.appendLE(UInt16(e.name.count))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt32(0o100644) << 16)
            out.appendLE(e.offset)
            out.append(e.name)
        }
        let directorySize = UInt32(out.count) - directoryStart
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(directorySize)
        out.appendLE(directoryStart)
        out.appendLE(UInt16(0))
        return out
    }

    func write(to url: URL) throws {
        try finish().write(to: url, options: .atomic)
    }
}

/// Minimal ZIP reader for the package formats Grapefruit opens (EPUB, XLSX, ODS, DOCX, PPTX).
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    let data: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        // The end-of-central-directory record sits in the last 64KB.
        let count = data.count
        guard count >= 22 else { throw JobError.failed("This file is damaged or isn't a ZIP package.") }
        var eocd = -1
        var i = count - 22
        let floor = max(0, count - 65_557)
        while i >= floor {
            if data.u32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw JobError.failed("This file is damaged or isn't a ZIP package.") }
        let total = Int(data.u16(at: eocd + 10))
        var p = Int(data.u32(at: eocd + 16))
        for _ in 0..<total {
            guard p + 46 <= count, data.u32(at: p) == 0x02014b50 else { break }
            let method = data.u16(at: p + 10)
            let csize = Int(data.u32(at: p + 20))
            let size = Int(data.u32(at: p + 24))
            let nameLength = Int(data.u16(at: p + 28))
            let extraLength = Int(data.u16(at: p + 30))
            let commentLength = Int(data.u16(at: p + 32))
            let offset = Int(data.u32(at: p + 42))
            guard p + 46 + nameLength <= count else { break }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, size: size, headerOffset: offset)
            names.append(name)
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data {
        guard let e = entries[name] ?? entries.first(where: { $0.key.lowercased() == name.lowercased() })?.value else {
            throw JobError.failed("Missing \(name) inside the package.")
        }
        let h = e.headerOffset
        guard data.u32(at: h) == 0x04034b50 else { throw JobError.failed("This package is damaged.") }
        let start = h + 30 + Int(data.u16(at: h + 26)) + Int(data.u16(at: h + 28))
        guard start + e.compressedSize <= data.count else { throw JobError.failed("This package is damaged.") }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8:
            guard let out = Deflate.decompress(raw, expectedSize: e.size) else {
                throw JobError.failed("Couldn't unpack \(name).")
            }
            return out
        default:
            throw JobError.failed("\(name) uses a compression Grapefruit can't read.")
        }
    }

    func text(_ name: String) throws -> String {
        String(decoding: try read(name), as: UTF8.self)
    }
}

enum Deflate {
    /// Raw DEFLATE (what ZIP stores), via Apple's Compression framework.
    static func compress(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func u16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

/// XML text escaping for the package writers.
extension String {
    var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for ch in unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Control characters other than tab and newlines aren't allowed in XML 1.0.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
