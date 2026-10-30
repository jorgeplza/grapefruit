import AppKit

/// Text documents: Word, Pages, Markdown, RTF, plain text, HTML, EPUB and text clippings.
enum DocumentEngine {
    /// A loaded document: its own formatting when it has some, plus its structure.
    struct Loaded {
        var attributed: NSAttributedString?
        var model: DocModel
    }

    static func load(_ url: URL, format: String, ctx: JobContext) throws -> Loaded {
        let stem = Output.stem(url)
        switch format {
        case "docx":
            return Loaded(attributed: nil, model: try DOCX.read(url, title: stem))
        case "rtf", "rtfd":
            let type: NSAttributedString.DocumentType = format == "rtf" ? .rtf : .rtfd
            let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            return Loaded(attributed: text, model: RichText.model(text, title: stem))
        case "textClipping":
            return try loadClipping(url, stem: stem)
        case "pages":
            let docx = try OfficeBridge.exportPages(url, as: "docx", ctx: ctx)
            defer { try? FileManager.default.removeItem(at: docx) }
            return try load(docx, format: "docx", ctx: ctx)
        case "md":
            let text = try readText(url)
            return Loaded(attributed: nil, model: Markdown.read(text, title: stem, baseURL: url.deletingLastPathComponent()))
        case "html":
            let data = try Data(contentsOf: url)
            let base = url.deletingLastPathComponent()
            return Loaded(attributed: nil, model: HTMLDoc.read(data, title: stem) { Resources.load($0, relativeTo: base) })
        case "epub":
            return Loaded(attributed: nil, model: try EPUB.read(url, title: stem))
        default:
            return Loaded(attributed: nil, model: PlainText.read(try readText(url), title: stem))
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Text clippings keep their contents as a property list keyed by type.
    private static func loadClipping(_ url: URL, stem: String) throws -> Loaded {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["UTI-Data"] as? [String: Any] else {
            throw JobError.failed("Couldn't read this text clipping.")
        }
        if let rtf = items["public.rtf"] as? Data,
           let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return Loaded(attributed: text, model: RichText.model(text, title: stem))
        }
        if let html = items["public.html"] as? Data {
            return Loaded(attributed: nil, model: HTMLDoc.read(html, title: stem) { Resources.load($0, relativeTo: nil) })
        }
        let plain = (items["public.utf8-plain-text"] as? String)
            ?? (items["public.utf8-plain-text"] as? Data).map { String(decoding: $0, as: UTF8.self) }
            ?? (items["public.utf16-plain-text"] as? Data).flatMap { String(data: $0, encoding: .utf16) }
            ?? ""
        guard !plain.isEmpty else { throw JobError.failed("This text clipping is empty.") }
        return Loaded(attributed: nil, model: PlainText.read(plain, title: stem))
    }

    static func convert(_ src: URL, format: String, to target: String, ctx: JobContext) throws -> [URL] {
        ctx.progress(0.05)
        let loaded = try load(src, format: format, ctx: ctx)
        try ctx.checkCancelled()
        ctx.progress(0.3)
        return try write(loaded, as: target, stem: Output.stem(src), ctx: ctx)
    }

    static func write(_ model: DocModel, as target: String, stem: String, ctx: JobContext) throws -> [URL] {
        try write(Loaded(attributed: nil, model: model), as: target, stem: stem, ctx: ctx)
    }

    /// Writes a loaded document as `target` into the job's scratch folder.
    static func write(_ doc: Loaded, as target: String, stem: String, ctx: JobContext) throws -> [URL] {
        let out = ctx.output("\(stem).\(Catalog.fileExtension(for: target))")
        // Documents with their own formatting keep it for Word, PDF and image output.
        func attributed() -> NSAttributedString { doc.attributed ?? RichText.attributed(doc.model) }

        switch target {
        case "docx":
            try DOCX.write(doc.model, to: out)
        case "rtf":
            let text = attributed()
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: out)
        case "pdf":
            try RichText.writePDF(attributed(), to: out, ctx: ctx)
        case "png", "jpg":
            let temp = try ctx.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: temp) }
            let pdf = temp.appendingPathComponent("\(stem).pdf")
            try RichText.writePDF(attributed(), to: pdf, ctx: ctx)
            return try PDFEngine.toImages(pdf, format: target, ctx: ctx)
        case "txt":
            try PlainText.write(doc.model.structural).write(to: out, atomically: true, encoding: .utf8)
        case "md":
            // The file links to its images folder by name, so both take a name that's free where they'll land.
            let free = ctx.freeStem(stem) { ["\($0).md", "\($0) images"] }
            let out = ctx.output("\(free).md")
            let folderName = "\(free) images"
            let (text, images) = Markdown.write(doc.model.structural, imageFolder: folderName)
            try text.write(to: out, atomically: true, encoding: .utf8)
            guard !images.isEmpty else { return [out] }
            let folder = ctx.output(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for image in images { try image.data.write(to: folder.appendingPathComponent(image.name)) }
            return [out, folder]
        case "html":
            try HTMLDoc.write(doc.model.structural).write(to: out, atomically: true, encoding: .utf8)
        case "epub":
            try EPUB.write(doc.model.structural, to: out)
        case "pages":
            let temp = try ctx.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: temp) }
            let docx = temp.appendingPathComponent("\(stem).docx")
            try DOCX.write(doc.model, to: docx)
            try OfficeBridge.convertWithPages(docx, to: out, ctx: ctx)
        default:
            throw JobError.failed("Can't write \(target.uppercased()) documents.")
        }
        ctx.progress(1)
        return [out]
    }
}
