import AppKit

/// Routes a file to the engine that handles its family.
enum Converter {
    static func convert(_ src: URL, to target: String, ctx: JobContext) throws -> [URL] {
        let format = Catalog.format(of: src) ?? src.pathExtension.lowercased()
        switch Catalog.family(format) {
        case "image":
            return try ImageEngine.convert(src, format: format, to: target, ctx: ctx)
        case "audio", "video":
            return try MediaEngine.convert(src, format: format, to: target, ctx: ctx)
        case "pdf":
            return try PDFEngine.convert(src, to: target, ctx: ctx)
        case "slides":
            return try SlidesEngine.convert(src, to: target, ctx: ctx)
        case "sheet":
            return try SheetEngine.convert(src, format: format, to: target, ctx: ctx)
        case "document":
            return try DocumentEngine.convert(src, format: format, to: target, ctx: ctx)
        case "subtitle":
            return try SubtitleEngine.convert(src, format: format, to: target, ctx: ctx)
        case "archive":
            return try ArchiveEngine.convert(src, format: format, to: target, ctx: ctx)
        default:
            throw JobError.failed("Grapefruit can't convert \(format.uppercased()) files.")
        }
    }

    /// One job step per file.
    static func steps(for files: [URL], to target: String) -> [JobStep] {
        files.map { url in
            JobStep(name: url.lastPathComponent, destination: url.deletingLastPathComponent()) { ctx in
                try convert(url, to: target, ctx: ctx)
            }
        }
    }
}

// MARK: - Slides

enum SlidesEngine {
    static func convert(_ src: URL, to target: String, ctx: JobContext) throws -> [URL] {
        ctx.progress(0.05)
        let exported = try OfficeBridge.slidesToPDF(src, ctx: ctx)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        ctx.progress(0.6)
        let stem = Output.stem(src)
        if target == "pdf" {
            let out = ctx.output("\(stem).pdf")
            try FileManager.default.copyItem(at: exported, to: out)
            ctx.progress(1)
            return [out]
        }
        // Render under the deck's own name.
        let temp = try ctx.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temp) }
        let named = temp.appendingPathComponent("\(stem).pdf")
        try FileManager.default.copyItem(at: exported, to: named)
        return try PDFEngine.toImages(named, format: target, ctx: ctx)
    }
}

// MARK: - Spreadsheets

enum SheetEngine {
    static func load(_ src: URL, format: String, ctx: JobContext) throws -> [Sheet] {
        switch format {
        case "csv": return [try DelimitedText.read(src, separator: nil)]
        case "tsv": return [try DelimitedText.read(src, separator: "\t")]
        case "xlsx": return try XLSX.read(src)
        case "ods": return try ODS.read(src)
        case "xls":
            let converted = try OfficeBridge.xlsToXLSX(src, ctx: ctx)
            defer { try? FileManager.default.removeItem(at: converted.deletingLastPathComponent()) }
            return try XLSX.read(converted)
        default:
            throw JobError.failed("Can't read \(format.uppercased()) spreadsheets.")
        }
    }

    static func convert(_ src: URL, format: String, to target: String, ctx: JobContext) throws -> [URL] {
        ctx.progress(0.1)
        let sheets = try load(src, format: format, ctx: ctx).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw JobError.failed("This spreadsheet is empty.") }
        try ctx.checkCancelled()
        ctx.progress(0.5)
        let stem = Output.stem(src)
        let out = ctx.output("\(stem).\(target)")
        switch target {
        case "xlsx":
            try XLSX.write(sheets, to: out)
        case "ods":
            try ODS.write(sheets, to: out)
        case "pdf":
            try SheetPDF.write(sheets, to: out, ctx: ctx)
        case "csv", "tsv":
            let separator: Character = target == "csv" ? "," : "\t"
            if sheets.count == 1 {
                try DelimitedText.write(sheets[0], separator: separator).write(to: out, atomically: true, encoding: .utf8)
            } else {
                // One file per sheet, in a folder.
                let folder = ctx.output(stem)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (sheet, name) in zip(sheets, XLSX.uniqueNames(sheets.map(\.name))) {
                    let file = folder.appendingPathComponent("\(name).\(target)")
                    try DelimitedText.write(sheet, separator: separator).write(to: file, atomically: true, encoding: .utf8)
                }
                ctx.progress(1)
                return [folder]
            }
        default:
            throw JobError.failed("Can't write \(target.uppercased()) spreadsheets.")
        }
        ctx.progress(1)
        return [out]
    }
}

// MARK: - Subtitles

enum SubtitleEngine {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues
    }

    /// "01:02:03,456", "02:03.456" or "02:03,456".
    static func time(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else { return nil }
        return numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
    }

    static func stamp(_ seconds: Double, comma: Bool) -> String {
        let ms = Int((seconds * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, comma ? "," : ".", f)
    }

    /// WebVTT voice and class tags mean nothing in SRT; keep only <b>, <i> and <u>.
    static func srtText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<(?!/?[biu]>)[^>]*>"#, with: "", options: .regularExpression)
    }

    static func convert(_ src: URL, format: String, to target: String, ctx: JobContext) throws -> [URL] {
        let cues = parse(try DocumentEngine.readText(src))
        guard !cues.isEmpty else { throw JobError.failed("No subtitles found in this file.") }
        let out = ctx.output(Output.name(src, ext: target))
        var text = ""
        switch target {
        case "srt":
            text = cues.enumerated().map { i, c in
                "\(i + 1)\n\(stamp(c.start, comma: true)) --> \(stamp(c.end, comma: true))\n\(srtText(c.text))"
            }.joined(separator: "\n\n") + "\n"
        case "vtt":
            text = "WEBVTT\n\n" + cues.map { c in
                "\(stamp(c.start, comma: false)) --> \(stamp(c.end, comma: false))\n\(c.text)"
            }.joined(separator: "\n\n") + "\n"
        case "txt":
            text = cues.map { $0.text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression) }
                .joined(separator: "\n") + "\n"
        default:
            throw JobError.failed("Can't write \(target.uppercased()) subtitles.")
        }
        try text.write(to: out, atomically: true, encoding: .utf8)
        ctx.progress(1)
        return [out]
    }
}

// MARK: - Archives

enum ArchiveEngine {
    /// Unpacks into `folder`.
    static func extract(_ src: URL, format: String, into folder: URL, ctx: JobContext) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if format == "zip" {
            try Shell.run(Binaries.ditto, ["-x", "-k", src.path, folder.path], ctx: ctx)
        } else {
            // bsdtar reads tar, gzip, bzip2, xz, 7z, rar and zip.
            try Shell.run(Binaries.tar, ["-x", "-f", src.path, "-C", folder.path], ctx: ctx)
        }
        // Finder's resource-fork leftovers aren't content.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("__MACOSX"))
    }

    static func contents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }.sorted()
    }

    static func convert(_ src: URL, format: String, to target: String, ctx: JobContext) throws -> [URL] {
        let temp = try ctx.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temp) }
        ctx.progress(0.1)
        try extract(src, format: format, into: temp, ctx: ctx)
        ctx.progress(0.5)
        let items = try contents(temp)
        guard !items.isEmpty else { throw JobError.failed("This archive is empty.") }
        let out = ctx.output(Output.name(src, ext: Catalog.fileExtension(for: target)))
        try pack(items, in: temp, as: target, to: out, ctx: ctx)
        ctx.progress(1)
        return [out]
    }

    /// Packs `items` (names inside `folder`) as zip, tar or tar.gz.
    static func pack(_ items: [String], in folder: URL, as target: String, to out: URL, ctx: JobContext) throws {
        let env = ["COPYFILE_DISABLE": "1"]
        switch target {
        case "zip":
            if items.count == 1 {
                try Shell.run(Binaries.ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                               folder.appendingPathComponent(items[0]).path, out.path], ctx: ctx)
            } else {
                try Shell.run(Binaries.ditto, ["-c", "-k", "--sequesterRsrc", folder.path, out.path], ctx: ctx)
            }
        case "tar":
            try Shell.run(Binaries.tar, ["-c", "-f", out.path, "-C", folder.path] + items, ctx: ctx, environment: env)
        case "gz":
            try Shell.run(Binaries.tar, ["-c", "-z", "-f", out.path, "-C", folder.path] + items, ctx: ctx, environment: env)
        default:
            throw JobError.failed("Can't make \(target.uppercased()) archives.")
        }
    }

    /// Unpacks next to the archive. A single top-level folder comes out as itself, not nested.
    static func extractHere(_ src: URL, ctx: JobContext) throws -> [URL] {
        let format = Catalog.format(of: src) ?? "zip"
        let temp = try ctx.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temp) }
        try extract(src, format: format, into: temp, ctx: ctx)
        ctx.progress(0.8)
        let items = try contents(temp)
        guard !items.isEmpty else { throw JobError.failed("This archive is empty.") }
        if items.count == 1 {
            let only = temp.appendingPathComponent(items[0])
            let out = ctx.output(items[0])
            try FileManager.default.moveItem(at: only, to: out)
            return [out]
        }
        let out = ctx.output(Output.stem(src))
        try FileManager.default.moveItem(at: temp, to: out)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return [out]
    }
}
