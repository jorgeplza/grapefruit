import Accelerate
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import zlib

/// Shared by the Compress and Metadata windows: file facts, the ffprobe reader,
/// a few view pieces, and the byte-level helpers (zlib, PNG, EXIF, XMP) both lean on.
enum FileToolKit {
    // MARK: Kinds and sizes

    enum Kind: String {
        case image, video, audio, pdf, other
    }

    static func format(of url: URL) -> String {
        Catalog.format(of: url) ?? url.pathExtension.lowercased()
    }

    static func kind(of url: URL) -> Kind {
        let f = format(of: url)
        if f == "gif" || Catalog.isImage(f) { return .image }
        if Catalog.isVideo(f) { return .video }
        if Catalog.isAudio(f) { return .audio }
        if f == "pdf" { return .pdf }
        return .other
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        return Int64(values?.fileSize ?? values?.totalFileSize ?? 0)
    }

    /// "3.4 MB", the way Finder writes sizes.
    static func bytes(_ n: Int64) -> String {
        n <= 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Plural nouns for a kind of file ("photos", "videos").
    static func noun(_ kind: Kind?, count: Int) -> String {
        let one = count == 1
        switch kind {
        case .image: return one ? "photo" : "photos"
        case .video: return one ? "video" : "videos"
        case .audio: return one ? "audio file" : "audio files"
        case .pdf: return one ? "PDF" : "PDFs"
        default: return one ? "file" : "files"
        }
    }

    // MARK: Motion

    /// Fast, interruptible, no bounce. Reduced motion gets a short fade instead.
    static func motion(_ reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.12) : .spring(duration: 0.25, bounce: 0)
    }

    // MARK: Views

    /// The grey line naming the file (or how many) at the top of a window.
    struct FileLine: View {
        let urls: [URL]

        var body: some View {
            Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                .font(.system(size: 10))
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(urls.count == 1 ? urls[0].lastPathComponent : urls.prefix(12).map(\.lastPathComponent).joined(separator: "\n"))
        }
    }

    // MARK: Background work

    /// Runs `work` off the main thread and hands the result back on it.
    static func background<T>(_ work: @escaping () -> T, then done: @escaping @MainActor (T) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(value) }
            }
        }
    }
}

// MARK: - Media probe

extension FileToolKit {
    struct Tag: Hashable, Sendable {
        var key: String
        var value: String
    }

    /// What ffprobe says about an audio or video file, with the tags kept.
    struct MediaInfo: Sendable {
        struct Stream: Sendable {
            var index = 0
            var type = ""
            var codec = ""
            var isCover = false
            var width = 0
            var height = 0
            var rotation = 0
            var fps: Double = 0
            var pixelFormat = ""
            var transfer = ""
            var primaries = ""
            var matrix = ""
            var bitRate: Int64 = 0
            var sampleRate = 0
            var channels = 0
            var bitsPerSample = 0
            var tags: [Tag] = []
        }

        var container = ""
        var duration: Double = 0
        var bitRate: Int64 = 0
        var tags: [Tag] = []
        var streams: [Stream] = []
        var chapters: [String] = []

        var video: Stream? { streams.first { $0.type == "video" && !$0.isCover } }
        var audio: [Stream] { streams.filter { $0.type == "audio" } }
        var covers: [Stream] { streams.filter { $0.isCover } }
        var isHDR: Bool { ["arib-std-b67", "smpte2084"].contains(video?.transfer ?? "") }
        var is10Bit: Bool { (video?.pixelFormat ?? "").contains("10") || (video?.pixelFormat ?? "").contains("12") }

        /// Picture size as shown, after rotation.
        var displaySize: (width: Int, height: Int) {
            guard let v = video else { return (0, 0) }
            return abs(v.rotation) % 180 == 90 ? (v.height, v.width) : (v.width, v.height)
        }

        /// Bits per second of the picture alone, estimated when the stream doesn't say.
        var videoBitRate: Int64 {
            if let v = video, v.bitRate > 0 { return v.bitRate }
            let audioRate = audio.reduce(Int64(0)) { $0 + max($1.bitRate, 0) }
            return max(0, bitRate - audioRate)
        }
    }

    static func probeMedia(_ url: URL, ctx: JobContext? = nil) throws -> MediaInfo {
        let ffprobe = try Binaries.require(Binaries.ffprobe, "ffmpeg")
        let result = try Shell.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams",
                                             "-show_chapters", url.path], ctx: ctx, timeout: 60)
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw JobError.failed("Couldn't read this file.")
        }
        func text(_ any: Any?) -> String {
            switch any {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        func tags(_ any: Any?) -> [Tag] {
            guard let dict = any as? [String: Any] else { return [] }
            return dict.map { Tag(key: $0.key, value: text($0.value)) }.sorted { $0.key < $1.key }
        }
        var info = MediaInfo()
        if let format = json["format"] as? [String: Any] {
            info.container = text(format["format_name"])
            info.duration = Double(text(format["duration"])) ?? 0
            info.bitRate = Int64(text(format["bit_rate"])) ?? 0
            info.tags = tags(format["tags"])
        }
        for raw in (json["streams"] as? [[String: Any]]) ?? [] {
            var s = MediaInfo.Stream()
            s.index = raw["index"] as? Int ?? 0
            s.type = text(raw["codec_type"])
            s.codec = text(raw["codec_name"])
            s.isCover = ((raw["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            s.width = raw["width"] as? Int ?? 0
            s.height = raw["height"] as? Int ?? 0
            s.pixelFormat = text(raw["pix_fmt"])
            s.transfer = text(raw["color_transfer"])
            s.primaries = text(raw["color_primaries"])
            s.matrix = text(raw["color_space"])
            s.bitRate = Int64(text(raw["bit_rate"])) ?? 0
            s.sampleRate = Int(text(raw["sample_rate"])) ?? 0
            s.channels = raw["channels"] as? Int ?? 0
            s.bitsPerSample = Int(text(raw["bits_per_raw_sample"])) ?? 0
            s.tags = tags(raw["tags"])
            let rate = text(raw["avg_frame_rate"]).isEmpty ? text(raw["r_frame_rate"]) : text(raw["avg_frame_rate"])
            let parts = rate.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { s.fps = parts[0] / parts[1] }
            if let r = s.tags.first(where: { $0.key == "rotate" }), let v = Int(r.value) { s.rotation = v }
            for side in (raw["side_data_list"] as? [[String: Any]]) ?? [] {
                if let r = side["rotation"] as? NSNumber { s.rotation = r.intValue }
            }
            if info.duration == 0, let d = Double(text(raw["duration"])) { info.duration = d }
            info.streams.append(s)
        }
        for chapter in (json["chapters"] as? [[String: Any]]) ?? [] {
            let title = (chapter["tags"] as? [String: Any]).map { text($0["title"]) } ?? ""
            info.chapters.append(title)
        }
        guard !info.streams.isEmpty else { throw JobError.failed("Couldn't read this file.") }
        return info
    }
}

// MARK: - Bytes

extension FileToolKit {
    /// Bounds-checked readers and writers for parsing file formats. Out of range reads give 0.
    enum Bytes {
        static func u8(_ b: [UInt8], _ i: Int) -> Int {
            i >= 0 && i < b.count ? Int(b[i]) : 0
        }

        static func u16(_ b: [UInt8], _ i: Int, little: Bool = false) -> Int {
            guard i >= 0, i + 2 <= b.count else { return 0 }
            return little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])
        }

        static func u32(_ b: [UInt8], _ i: Int, little: Bool = false) -> Int {
            guard i >= 0, i + 4 <= b.count else { return 0 }
            let v0 = Int(b[i]), v1 = Int(b[i + 1]), v2 = Int(b[i + 2]), v3 = Int(b[i + 3])
            return little ? v0 | v1 << 8 | v2 << 16 | v3 << 24 : v0 << 24 | v1 << 16 | v2 << 8 | v3
        }

        static func u64(_ b: [UInt8], _ i: Int) -> Int {
            guard i >= 0, i + 8 <= b.count else { return 0 }
            var v = 0
            for k in 0..<8 { v = v << 8 | Int(b[i + k]) }
            return v
        }

        /// A big-endian unsigned integer of `size` bytes (0, 4 or 8 in ISO boxes).
        static func uint(_ b: [UInt8], _ i: Int, size: Int) -> Int {
            switch size {
            case 1: return u8(b, i)
            case 2: return u16(b, i)
            case 4: return u32(b, i)
            case 8: return u64(b, i)
            default: return 0
            }
        }

        static func put(_ b: inout [UInt8], _ i: Int, _ v: Int, size: Int, little: Bool = false) {
            guard i >= 0, i + size <= b.count else { return }
            for k in 0..<size {
                let shift = little ? 8 * k : 8 * (size - 1 - k)
                b[i + k] = UInt8(truncatingIfNeeded: v >> shift)
            }
        }

        static func be32(_ v: Int) -> [UInt8] {
            [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        }

        static func le32(_ v: Int) -> [UInt8] {
            [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
        }

        static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

        static func string(_ b: ArraySlice<UInt8>) -> String {
            String(decoding: b, as: UTF8.self)
        }

        /// Latin-1 text (PNG tEXt, GIF comments), falling back to UTF-8 when it reads cleanly as that.
        static func latin1(_ b: ArraySlice<UInt8>) -> String {
            if let utf8 = String(bytes: b, encoding: .utf8) { return utf8 }
            return String(bytes: b, encoding: .isoLatin1) ?? ""
        }

        static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
            let end = min(to ?? hay.count, hay.count)
            guard !needle.isEmpty, from >= 0, end - from >= needle.count else { return nil }
            let first = needle[0]
            var i = from
            let last = end - needle.count
            while i <= last {
                if hay[i] == first {
                    var match = true
                    for k in 1..<needle.count where hay[i + k] != needle[k] {
                        match = false
                        break
                    }
                    if match { return i }
                }
                i += 1
            }
            return nil
        }
    }
}

// MARK: - zlib

extension FileToolKit {
    enum Deflate {
        static func crc32(_ parts: [UInt8]...) -> UInt32 {
            var c = zlib.crc32(0, nil, 0)
            for p in parts {
                p.withUnsafeBufferPointer { c = zlib.crc32(c, $0.baseAddress, uInt($0.count)) }
            }
            return UInt32(truncatingIfNeeded: c)
        }

        /// Inflates a zlib stream (or raw deflate). Nil for broken or oversized data.
        static func inflate(_ input: [UInt8], raw: Bool = false, limit: Int = 128 << 20) -> [UInt8]? {
            guard !input.isEmpty else { return nil }
            var strm = z_stream()
            guard inflateInit2_(&strm, raw ? -15 : 15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&strm) }
            var output: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            return input.withUnsafeBufferPointer { inBuf -> [UInt8]? in
                strm.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                strm.avail_in = uInt(inBuf.count)
                while true {
                    var status: Int32 = Z_OK
                    let produced = chunk.withUnsafeMutableBufferPointer { out -> Int in
                        strm.next_out = out.baseAddress
                        strm.avail_out = uInt(out.count)
                        status = zlib.inflate(&strm, Z_NO_FLUSH)
                        return out.count - Int(strm.avail_out)
                    }
                    output.append(contentsOf: chunk[0..<produced])
                    if output.count > limit { return nil }
                    if status == Z_STREAM_END { return output }
                    if status != Z_OK { return nil }
                    if strm.avail_in == 0 && produced == 0 { return nil }
                }
            }
        }

        /// A zlib stream for `data`, deflated in parallel slices (each primed with the
        /// previous 32 KB, the way pigz does it), so big PNGs don't take ages.
        static func zlibStream(_ data: UnsafeBufferPointer<UInt8>, level: Int32 = 9, strategy: Int32 = Z_DEFAULT_STRATEGY) -> [UInt8] {
            let n = data.count
            guard let base = data.baseAddress, n > 0 else {
                // An empty stream: header, one empty final block, adler of nothing.
                return [0x78, 0xDA, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
            }
            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let blockSize = max(1 << 20, (n + cores * 2 - 1) / (cores * 2))
            let count = (n + blockSize - 1) / blockSize
            var pieces = [[UInt8]](repeating: [], count: count)
            var adlers = [uLong](repeating: 1, count: count)
            pieces.withUnsafeMutableBufferPointer { pieceSlots in
                adlers.withUnsafeMutableBufferPointer { adlerSlots in
                    DispatchQueue.concurrentPerform(iterations: count) { i in
                        let start = i * blockSize
                        let end = min(n, start + blockSize)
                        var strm = z_stream()
                        guard deflateInit2_(&strm, level, Z_DEFLATED, -15, 9, strategy, zlibVersion(),
                                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                        if i > 0 {
                            let dictStart = max(0, start - 32_768)
                            deflateSetDictionary(&strm, base + dictStart, uInt(start - dictStart))
                        }
                        let bound = Int(deflateBound(&strm, uLong(end - start))) + 64
                        var out = [UInt8](repeating: 0, count: bound)
                        let produced = out.withUnsafeMutableBufferPointer { o -> Int in
                            strm.next_in = UnsafeMutablePointer(mutating: base + start)
                            strm.avail_in = uInt(end - start)
                            strm.next_out = o.baseAddress
                            strm.avail_out = uInt(o.count)
                            _ = zlib.deflate(&strm, i == count - 1 ? Z_FINISH : Z_SYNC_FLUSH)
                            return o.count - Int(strm.avail_out)
                        }
                        deflateEnd(&strm)
                        out.removeSubrange(produced...)
                        pieceSlots[i] = out
                        adlerSlots[i] = adler32(1, base + start, uInt(end - start))
                    }
                }
            }
            var adler = adlers[0]
            for i in 1..<count {
                let length = min(n, (i + 1) * blockSize) - i * blockSize
                adler = adler32_combine(adler, adlers[i], length)
            }
            var result: [UInt8] = [0x78, 0xDA]
            result.reserveCapacity(pieces.reduce(6) { $0 + $1.count })
            for p in pieces { result += p }
            result += Bytes.be32(Int(adler))
            return result
        }
    }
}

// MARK: - PNG

extension FileToolKit {
    enum PNG {
        static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        static let xmpKeyword = "XML:com.adobe.xmp"

        struct Chunk {
            var type: String
            var data: [UInt8]
        }

        static func chunks(_ b: [UInt8]) -> [Chunk]? {
            guard b.count >= 8, Array(b[0..<8]) == signature else { return nil }
            var out: [Chunk] = []
            var p = 8
            while p + 12 <= b.count {
                let length = Bytes.u32(b, p)
                let type = Bytes.string(b[(p + 4)..<(p + 8)])
                guard length >= 0, p + 12 + length <= b.count else { return nil }
                out.append(Chunk(type: type, data: Array(b[(p + 8)..<(p + 8 + length)])))
                p += 12 + length
                if type == "IEND" { break }
            }
            guard out.first?.type == "IHDR", out.last?.type == "IEND" else { return nil }
            return out
        }

        static func serialize(_ chunks: [Chunk]) -> [UInt8] {
            var out = signature
            out.reserveCapacity(chunks.reduce(8) { $0 + $1.data.count + 12 })
            for c in chunks {
                let type = Bytes.ascii(c.type)
                out += Bytes.be32(c.data.count)
                out += type
                out += c.data
                out += Bytes.be32(Int(Deflate.crc32(type, c.data)))
            }
            return out
        }

        /// Keyword and text of a tEXt, zTXt or iTXt chunk.
        static func text(_ c: Chunk) -> (keyword: String, text: String)? {
            let d = c.data
            guard let zero = d.firstIndex(of: 0) else { return nil }
            let keyword = Bytes.latin1(d[0..<zero])
            switch c.type {
            case "tEXt":
                return (keyword, Bytes.latin1(d[(zero + 1)...]))
            case "zTXt":
                guard zero + 2 <= d.count, let raw = Deflate.inflate(Array(d[(zero + 2)...]), limit: 8 << 20) else { return nil }
                return (keyword, Bytes.latin1(raw[...]))
            case "iTXt":
                guard zero + 3 <= d.count else { return nil }
                let compressed = d[zero + 1] == 1
                var p = zero + 3
                guard let langEnd = d[p...].firstIndex(of: 0) else { return nil }
                p = langEnd + 1
                guard let transEnd = d[p...].firstIndex(of: 0) else { return nil }
                p = transEnd + 1
                let body = Array(d[p...])
                if compressed {
                    guard let raw = Deflate.inflate(body, limit: 16 << 20) else { return nil }
                    return (keyword, Bytes.string(raw[...]))
                }
                return (keyword, Bytes.string(body[...]))
            default:
                return nil
            }
        }

        static func isText(_ c: Chunk) -> Bool { ["tEXt", "zTXt", "iTXt"].contains(c.type) }

        static func isXMP(_ c: Chunk) -> Bool {
            c.type == "iTXt" && c.data.starts(with: Bytes.ascii(xmpKeyword + "\0"))
        }

        static func xmpPacket(_ c: Chunk) -> [UInt8]? {
            guard isXMP(c), let t = text(c) else { return nil }
            return Bytes.ascii(t.text)
        }

        static func xmpChunk(_ packet: [UInt8]) -> Chunk {
            Chunk(type: "iTXt", data: Bytes.ascii(xmpKeyword) + [0, 0, 0, 0, 0] + packet)
        }

        /// tEXt when the text fits Latin-1, iTXt (UTF-8) otherwise.
        static func textChunk(keyword: String, text: String) -> Chunk {
            let key = Array((keyword.data(using: .isoLatin1) ?? Data(keyword.utf8)).prefix(79))
            if let latin = text.data(using: .isoLatin1) {
                return Chunk(type: "tEXt", data: key + [0] + [UInt8](latin))
            }
            return Chunk(type: "iTXt", data: key + [0, 0, 0, 0, 0] + Bytes.ascii(text))
        }

        /// Chunks that describe how to show the pixels: kept by both tools.
        static let displayChunks: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI", "pHYs"]

        // MARK: Encoder

        struct Raster {
            var width: Int
            var height: Int
            /// 0 grey, 2 RGB, 3 indexed, 4 grey + alpha, 6 RGBA.
            var colorType: UInt8
            var bitDepth: UInt8
            /// Packed rows, `rowBytes` each, no filter bytes.
            var rows: [UInt8]
            var palette: [UInt8] = []
            var transparency: [UInt8] = []

            var channels: Int {
                switch colorType {
                case 0, 3: return 1
                case 4: return 2
                case 2: return 3
                default: return 4
                }
            }

            var rowBytes: Int { (width * channels * Int(bitDepth) + 7) / 8 }
        }

        /// A complete PNG: the raster, then `extra` chunks (colour, DPI, EXIF) in a valid order.
        static func encode(_ r: Raster, extra: [Chunk] = []) -> [UInt8] {
            var ihdr = Bytes.be32(r.width) + Bytes.be32(r.height)
            ihdr += [r.bitDepth, r.colorType, 0, 0, 0]
            var chunks = [Chunk(type: "IHDR", data: ihdr)]
            // Colour chunks must come before PLTE; the rest before IDAT.
            let beforePalette: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI", "sBIT"]
            chunks += extra.filter { beforePalette.contains($0.type) }
            if r.colorType == 3 {
                chunks.append(Chunk(type: "PLTE", data: r.palette))
            }
            if !r.transparency.isEmpty {
                chunks.append(Chunk(type: "tRNS", data: r.transparency))
            }
            chunks += extra.filter { !beforePalette.contains($0.type) }
            let stream = compressedRows(r)
            var p = 0
            let slice = 1 << 20
            repeat {
                let end = min(stream.count, p + slice)
                chunks.append(Chunk(type: "IDAT", data: Array(stream[p..<end])))
                p = end
            } while p < stream.count
            chunks.append(Chunk(type: "IEND", data: []))
            return serialize(chunks)
        }

        /// Filters every row and deflates the result. Each row gets the filter whose bytes come
        /// out least random (lowest entropy), then the stream is deflated two ways and the
        /// smaller one kept. Palettes stay unfiltered, which suits them best.
        static func compressedRows(_ r: Raster) -> [UInt8] {
            let rowBytes = r.rowBytes
            let stride = rowBytes + 1
            let height = r.height
            let bpp = max(1, r.channels * Int(r.bitDepth) / 8)
            let adaptive = r.colorType != 3 && r.bitDepth >= 8
            var filtered = [UInt8](repeating: 0, count: stride * height)
            r.rows.withUnsafeBufferPointer { src in
                filtered.withUnsafeMutableBufferPointer { dst in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                    let bands = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 4))
                    let perBand = (height + bands - 1) / bands
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let y0 = band * perBand
                        let y1 = min(height, y0 + perBand)
                        guard y0 < y1 else { return }
                        let width = max(1, rowBytes)
                        let zero = UnsafeMutablePointer<UInt8>.allocate(capacity: width)
                        zero.initialize(repeating: 0, count: width)
                        let candidates = UnsafeMutablePointer<UInt8>.allocate(capacity: width * 5)
                        defer {
                            zero.deallocate()
                            candidates.deallocate()
                        }
                        var histogram = [Int32](repeating: 0, count: 256)
                        for y in y0..<y1 {
                            let cur = s + y * rowBytes
                            let prev = y > 0 ? s + (y - 1) * rowBytes : UnsafePointer(zero)
                            let out = d + y * stride
                            guard adaptive else {
                                out[0] = 0
                                (out + 1).update(from: cur, count: rowBytes)
                                continue
                            }
                            var best = 0
                            var bestScore = -Double.infinity
                            for f in 0..<5 {
                                let row = candidates + f * width
                                applyFilter(f, cur: cur, prev: prev, bpp: bpp, count: rowBytes, into: row)
                                for i in 0..<256 { histogram[i] = 0 }
                                for x in 0..<rowBytes { histogram[Int(row[x])] += 1 }
                                // Higher sum of c·log2(c) means lower entropy.
                                var score = 0.0
                                for c in histogram where c > 1 {
                                    let v = Double(c)
                                    score += v * log2(v)
                                }
                                if score > bestScore {
                                    bestScore = score
                                    best = f
                                }
                            }
                            out[0] = UInt8(best)
                            (out + 1).update(from: candidates + best * width, count: rowBytes)
                        }
                    }
                }
            }
            return filtered.withUnsafeBufferPointer { data in
                guard adaptive else { return Deflate.zlibStream(data) }
                let matched = Deflate.zlibStream(data, strategy: Z_FILTERED)
                let runs = Deflate.zlibStream(data, strategy: Z_RLE)
                return matched.count <= runs.count ? matched : runs
            }
        }

        private static func applyFilter(_ f: Int, cur: UnsafePointer<UInt8>, prev: UnsafePointer<UInt8>, bpp: Int,
                                        count: Int, into out: UnsafeMutablePointer<UInt8>) {
            switch f {
            case 0:
                out.update(from: cur, count: count)
            case 1:
                for x in 0..<count { out[x] = cur[x] &- (x >= bpp ? cur[x - bpp] : 0) }
            case 2:
                for x in 0..<count { out[x] = cur[x] &- prev[x] }
            case 3:
                for x in 0..<count {
                    let a = x >= bpp ? Int(cur[x - bpp]) : 0
                    out[x] = cur[x] &- UInt8((a + Int(prev[x])) >> 1)
                }
            default:
                for x in 0..<count {
                    let a = x >= bpp ? Int(cur[x - bpp]) : 0
                    let b = Int(prev[x])
                    let c = x >= bpp ? Int(prev[x - bpp]) : 0
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    out[x] = cur[x] &- UInt8(pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
                }
            }
        }
    }
}

// MARK: - EXIF

extension FileToolKit {
    enum EXIF {
        /// A big-endian TIFF block holding only an orientation, for files that must keep their rotation.
        static func orientationOnly(_ orientation: Int) -> [UInt8] {
            [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8,
             0, 1,
             0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, UInt8(clamping: orientation), 0, 0,
             0, 0, 0, 0]
        }

        /// The EXIF dictionaries ImageIO writes into a TIFF block.
        static let blockKeys: [CFString] = [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary,
                                            kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary]

        /// An EXIF block (TIFF bytes) written by ImageIO from properties, by way of a tiny
        /// JPEG. ImageIO stamps the tiny image's size into it, so the real one is patched back.
        static func block(from props: [CFString: Any], width: Int, height: Int) -> [UInt8]? {
            var clean: [CFString: Any] = [:]
            for key in blockKeys {
                if let dict = props[key] as? [CFString: Any], !dict.isEmpty { clean[key] = dict }
            }
            guard !clean.isEmpty else { return nil }
            if let o = props[kCGImagePropertyOrientation] { clean[kCGImagePropertyOrientation] = o }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
                  let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let tiny = ctx.makeImage() else { return nil }
            CGImageDestinationAddImage(dest, tiny, clean as CFDictionary)
            guard CGImageDestinationFinalize(dest), var tiff = fromJPEG([UInt8](data as Data)) else { return nil }
            patchDimensions(&tiff, width: width, height: height)
            return tiff
        }

        /// The TIFF bytes inside a JPEG's APP1 Exif segment.
        static func fromJPEG(_ b: [UInt8]) -> [UInt8]? {
            for segment in JPEG.segments(b) where segment.marker == 0xE1 {
                let body = Array(b[segment.body])
                if body.starts(with: [0x45, 0x78, 0x69, 0x66, 0, 0]) { return Array(body[6...]) }
            }
            return nil
        }

        struct Entry {
            var tag: Int
            var type: Int
            var count: Int
            /// Where the 4-byte value (or offset to it) sits.
            var valuePos: Int
        }

        static func entries(_ t: [UInt8], ifd: Int, little: Bool) -> [Entry] {
            let n = Bytes.u16(t, ifd, little: little)
            guard ifd > 0, n > 0, n < 1000, ifd + 2 + n * 12 <= t.count else { return [] }
            return (0..<n).map { k in
                let p = ifd + 2 + k * 12
                return Entry(tag: Bytes.u16(t, p, little: little), type: Bytes.u16(t, p + 2, little: little),
                             count: Bytes.u32(t, p + 4, little: little), valuePos: p + 8)
            }
        }

        static func header(_ t: [UInt8]) -> (little: Bool, ifd0: Int)? {
            guard t.count >= 8 else { return nil }
            let little = t[0] == 0x49 && t[1] == 0x49
            guard little || (t[0] == 0x4D && t[1] == 0x4D), Bytes.u16(t, 2, little: little) == 42 else { return nil }
            return (little, Bytes.u32(t, 4, little: little))
        }

        /// Points the ExifIFD's pixel size tags at the real image size.
        static func patchDimensions(_ t: inout [UInt8], width: Int, height: Int) {
            guard let (little, ifd0) = header(t) else { return }
            guard let pointer = entries(t, ifd: ifd0, little: little).first(where: { $0.tag == 0x8769 }) else { return }
            let exifIFD = Bytes.u32(t, pointer.valuePos, little: little)
            for e in entries(t, ifd: exifIFD, little: little) where e.tag == 0xA002 || e.tag == 0xA003 {
                let value = e.tag == 0xA002 ? width : height
                if e.type == 3 && value <= 0xFFFF {
                    Bytes.put(&t, e.valuePos, value, size: 2, little: little)
                    Bytes.put(&t, e.valuePos + 2, 0, size: 2, little: little)
                } else {
                    Bytes.put(&t, e.valuePos - 6, 4, size: 2, little: little)
                    Bytes.put(&t, e.valuePos, value, size: 4, little: little)
                }
            }
        }

        /// The orientation tag in a TIFF block, if any.
        static func orientation(_ t: [UInt8]) -> Int? {
            guard let (little, ifd0) = header(t),
                  let e = entries(t, ifd: ifd0, little: little).first(where: { $0.tag == 0x0112 }) else { return nil }
            let v = Bytes.u16(t, e.valuePos, little: little)
            return (1...8).contains(v) ? v : nil
        }
    }

    // MARK: JPEG segments

    enum JPEG {
        struct Segment {
            var marker: UInt8
            /// Start of the 0xFF marker byte.
            var start: Int
            /// The payload after the two length bytes.
            var body: Range<Int>
        }

        /// Marker segments before the image data.
        static func segments(_ b: [UInt8]) -> [Segment] {
            guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return [] }
            var out: [Segment] = []
            var i = 2
            while i + 4 <= b.count {
                guard b[i] == 0xFF else { break }
                let marker = b[i + 1]
                if marker == 0xFF { i += 1; continue }
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                let length = Bytes.u16(b, i + 2)
                guard length >= 2, i + 2 + length <= b.count else { break }
                out.append(Segment(marker: marker, start: i, body: (i + 4)..<(i + 2 + length)))
                if marker == 0xDA { break }
                i += 2 + length
            }
            return out
        }

        static let xmpSignature = Bytes.ascii("http://ns.adobe.com/xap/1.0/\0")

        static func xmpPacket(_ b: [UInt8]) -> [UInt8]? {
            for s in segments(b) where s.marker == 0xE1 {
                let body = b[s.body]
                if body.starts(with: xmpSignature) { return Array(body.dropFirst(xmpSignature.count)) }
            }
            return nil
        }

        /// Text from COM segments.
        static func comments(_ b: [UInt8]) -> [String] {
            segments(b).filter { $0.marker == 0xFE }.map { Bytes.latin1(b[$0.body]) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
                .filter { !$0.isEmpty }
        }
    }
}

// MARK: - XMP

extension FileToolKit {
    enum XMP {
        static let packetID = "W5M0MpCehiHzreSzNTczkc9d"

        static func metadata(_ packet: [UInt8]) -> CGMutableImageMetadata? {
            guard !packet.isEmpty, let m = CGImageMetadataCreateFromXMPData(Data(packet) as CFData) else { return nil }
            return CGImageMetadataCreateMutableCopy(m)
        }

        static func hasTags(_ m: CGImageMetadata) -> Bool {
            var any = false
            CGImageMetadataEnumerateTagsUsingBlock(m, nil, nil) { _, _ in
                any = true
                return false
            }
            return any
        }

        /// The metadata as an XMP packet, or nil when nothing is left in it.
        static func serialize(_ m: CGImageMetadata) -> [UInt8]? {
            guard hasTags(m), let data = CGImageMetadataCreateXMPData(m, nil) else { return nil }
            return wrap([UInt8](data as Data))
        }

        /// Adds the xpacket processing instructions (and optional padding) around a bare xmpmeta.
        static func wrap(_ body: [UInt8], padding: Int = 0) -> [UInt8] {
            var core = body
            if let begin = Bytes.find(core, Bytes.ascii("<?xpacket begin")) {
                // Already a packet: keep only the xmpmeta part and rebuild the wrapper.
                if let close = Bytes.find(core, Bytes.ascii("?>"), from: begin) { core = Array(core[(close + 2)...]) }
                if let end = Bytes.find(core, Bytes.ascii("<?xpacket end")) { core = Array(core[..<end]) }
            }
            while let last = core.last, last == 0x20 || last == 0x0A || last == 0x0D || last == 0x09 { core.removeLast() }
            let head = Bytes.ascii("<?xpacket begin=\"\u{FEFF}\" id=\"\(packetID)\"?>\n")
            let tail = Bytes.ascii("<?xpacket end=\"w\"?>")
            return head + core + [0x0A] + [UInt8](repeating: 0x20, count: max(0, padding)) + tail
        }

        /// An XMP packet with nothing in it.
        static let empty: [UInt8] = wrap(Bytes.ascii("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"/></x:xmpmeta>"))

        /// `packet` padded with whitespace to exactly `length` bytes, or nil if it doesn't fit.
        static func fit(_ packet: [UInt8], into length: Int) -> [UInt8]? {
            let bare = wrap(packet)
            guard bare.count <= length else { return nil }
            return wrap(packet, padding: length - bare.count)
        }

        static func path(_ tag: CGImageMetadataTag) -> String? {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
            return "\(prefix):\(name)"
        }

        /// A readable value for any tag: strings as-is, lists joined, structures summarised.
        static func describe(_ tag: CGImageMetadataTag) -> String {
            let value = CGImageMetadataTagCopyValue(tag)
            switch CGImageMetadataTagGetType(tag) {
            case .string:
                return (value as? String) ?? (value.map { "\($0)" } ?? "")
            case .arrayUnordered, .arrayOrdered, .alternateArray, .alternateText:
                let items = (value as? [CGImageMetadataTag]) ?? []
                return items.map { describe($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
            case .structure:
                let fields = (value as? [String: CGImageMetadataTag]) ?? [:]
                return fields.count == 1 ? "1 field" : "\(fields.count) fields"
            default:
                return (value as? String) ?? ""
            }
        }

        static func isSimple(_ tag: CGImageMetadataTag) -> Bool {
            CGImageMetadataTagGetType(tag) == .string
        }

        /// Removes every XMP tag ImageIO treats as the same thing as `dict`/`key` (dc:creator for Artist...).
        @discardableResult
        static func removeSynonyms(_ m: CGMutableImageMetadata, dict: CFString, key: CFString) -> Bool {
            var removed = false
            for _ in 0..<6 {
                guard let tag = CGImageMetadataCopyTagMatchingImageProperty(m, dict, key), let p = path(tag) else { break }
                guard CGImageMetadataRemoveTagWithPath(m, nil, p as CFString) else { break }
                removed = true
            }
            return removed
        }

        static func hasSynonym(_ m: CGImageMetadata, dict: CFString, key: CFString) -> Bool {
            CGImageMetadataCopyTagMatchingImageProperty(m, dict, key) != nil
        }

        /// Top-level tags with their paths.
        static func tags(_ m: CGImageMetadata) -> [(path: String, tag: CGImageMetadataTag)] {
            var out: [(String, CGImageMetadataTag)] = []
            CGImageMetadataEnumerateTagsUsingBlock(m, nil, nil) { path, tag in
                out.append((path as String, tag))
                return true
            }
            return out
        }

        /// Byte ranges of XMP packets sitting in plain sight inside a file (PDF streams, mostly).
        static func packetRanges(_ b: [UInt8]) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var from = 0
            let begin = Bytes.ascii("<?xpacket begin")
            let end = Bytes.ascii("<?xpacket end")
            while let s = Bytes.find(b, begin, from: from), let e = Bytes.find(b, end, from: s),
                  let close = Bytes.find(b, Bytes.ascii("?>"), from: e) {
                out.append(s..<(close + 2))
                from = close + 2
            }
            return out
        }
    }
}
