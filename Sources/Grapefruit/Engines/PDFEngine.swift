import AppKit
import PDFKit
import Vision

/// PDF in: pages to images, text (with OCR for scans), structure for Word/Markdown/EPUB, tables for Excel.
enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw JobError.failed("Couldn't open this PDF.") }
        if doc.isLocked { throw JobError.failed("This PDF is password protected.") }
        guard doc.pageCount > 0 else { throw JobError.failed("This PDF has no pages.") }
        return doc
    }

    // MARK: Rendering

    /// A page drawn on white at `scale` × 72 dpi.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = Int(((rotated ? box.height : box.width) * scale).rounded())
        let h = Int(((rotated ? box.width : box.height) * scale).rounded())
        guard w > 0, h > 0, w * h < 400_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// One image per page: a single file for one page, a folder for several.
    static func toImages(_ src: URL, format: String, ctx: JobContext, scale: CGFloat = 2) throws -> [URL] {
        let doc = try open(src)
        let stem = Output.stem(src)
        let count = doc.pageCount
        var folder = ctx.scratch
        if count > 1 {
            folder = ctx.output(stem)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let digits = String(count).count
        for i in 0..<count {
            try ctx.checkCancelled()
            guard let page = doc.page(at: i), let image = render(page, scale: scale) else { continue }
            let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            let name = count > 1 ? "\(stem) \(number).\(format)" : "\(stem).\(format)"
            let loaded = ImageEngine.Loaded(image: image, properties: [kCGImagePropertyDPIWidth: 72 * scale,
                                                                        kCGImagePropertyDPIHeight: 72 * scale],
                                            pointsPerPixel: 1 / scale)
            try ImageEngine.write(loaded, as: format, to: folder.appendingPathComponent(name), quality: 0.9, ctx: ctx)
            ctx.progress(Double(i + 1) / Double(count))
        }
        return [count > 1 ? folder : folder.appendingPathComponent("\(stem).\(format)")]
    }

    // MARK: Text

    static func plainText(_ doc: PDFDocument, ctx: JobContext) throws -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try ctx.checkCancelled()
            guard let page = doc.page(at: i) else { continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(ocrLines(page, index: i).map(\.text).joined(separator: "\n"))
            } else {
                pages.append(expandLigatures(text))
            }
            ctx.progress(0.9 * Double(i + 1) / Double(doc.pageCount))
        }
        return pages.joined(separator: "\n\n\u{0C}")
    }

    // MARK: Conversion

    static func convert(_ src: URL, to target: String, ctx: JobContext) throws -> [URL] {
        let stem = Output.stem(src)
        switch target {
        case "jpg", "png":
            return try toImages(src, format: target, ctx: ctx)
        case "txt":
            let text = try plainText(open(src), ctx: ctx)
            let out = ctx.output("\(stem).txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case "md":
            let model = try model(src, ctx: ctx)
            return try DocumentEngine.write(model, as: "md", stem: stem, ctx: ctx)
        case "docx", "epub", "pages":
            let model = try model(src, ctx: ctx)
            return try DocumentEngine.write(model, as: target, stem: stem, ctx: ctx)
        case "xlsx":
            let rows = try tableRows(src, ctx: ctx)
            let sheet = Sheet(name: "Sheet1", rows: rows.map { $0.map(CellValue.guess) })
            let out = ctx.output("\(stem).xlsx")
            try XLSX.write([sheet], to: out)
            return [out]
        case "pptx":
            let doc = try open(src)
            var slides: [Data] = []
            var size = CGSize(width: 960, height: 540)
            for i in 0..<doc.pageCount {
                try ctx.checkCancelled()
                guard let page = doc.page(at: i), let image = render(page, scale: 2) else { continue }
                if i == 0 { size = CGSize(width: image.width, height: image.height) }
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) { slides.append(png) }
                ctx.progress(0.9 * Double(i + 1) / Double(doc.pageCount))
            }
            let out = ctx.output("\(stem).pptx")
            try PPTX.write(slides: slides, aspect: size, to: out)
            return [out]
        default:
            throw JobError.failed("Can't turn a PDF into \(target.uppercased()).")
        }
    }

    // MARK: Tools that run instantly

    /// Every page as its own PDF, in a folder.
    static func split(_ src: URL, ctx: JobContext) throws -> [URL] {
        let doc = try open(src)
        let stem = Output.stem(src)
        let folder = ctx.output("\(stem) Pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            try ctx.checkCancelled()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            guard single.write(to: folder.appendingPathComponent("\(stem) \(number).pdf")) else {
                throw JobError.failed("Couldn't save page \(i + 1).")
            }
            ctx.progress(Double(i + 1) / Double(doc.pageCount))
        }
        return [folder]
    }

    /// Several PDFs, one after another.
    static func merge(_ sources: [URL], to out: URL, ctx: JobContext) throws {
        let merged = PDFDocument()
        for (n, url) in sources.enumerated() {
            try ctx.checkCancelled()
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
            ctx.progress(0.8 * Double(n + 1) / Double(sources.count))
        }
        guard merged.write(to: out) else { throw JobError.failed("Couldn't save the merged PDF.") }
    }
}
