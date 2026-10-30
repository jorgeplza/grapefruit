import AppKit
import PDFKit
import Vision

/// Reading structure back out of a PDF: lines with their styles and positions, then headings, lists, quotes,
/// code, tables and pictures for Word, Markdown and EPUB, or rows and columns for Excel.
extension PDFEngine {
    struct Cell {
        var runs: [Inline]
        var minX: CGFloat
        var maxX: CGFloat
        var text: String { Inlines.plain(runs) }
    }

    struct Line {
        var cells: [Cell]
        var minX: CGFloat
        var maxX: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var size: CGFloat
        var bold = false
        var italic = false
        var mono = false
        var page: Int
        var box: CGRect
        /// A picture that sits here instead of text, with its file type.
        var picture: (data: Data, ext: String)?
        /// Where each word starts and ends, left to right.
        var words: [ClosedRange<CGFloat>] = []
        /// The text column the line sits in, counting from the left. Nil when it spans the columns.
        var column: Int? = 0

        var height: CGFloat { top - bottom }

        var runs: [Inline] {
            var out: [Inline] = []
            for (i, cell) in cells.enumerated() {
                if i > 0 { out.append(Inline(text: " ")) }
                out += cell.runs
            }
            return out
        }

        var text: String { cells.map(\.text).joined(separator: " ") }
    }

    // MARK: Lines

    /// Lines with position, size and styled runs, page by page in reading order. Pages without text are read with OCR.
    static func lines(_ doc: PDFDocument, ctx: JobContext, pictures: Bool = false,
                      progress: ClosedRange<Double> = 0...0.8) throws -> [[Line]] {
        var pages: [[Line]] = []
        for i in 0..<doc.pageCount {
            try ctx.checkCancelled()
            guard let page = doc.page(at: i) else { pages.append([]); continue }
            let box = page.bounds(for: .cropBox)
            let text = (page.string ?? "") as NSString
            var result: [Line] = []
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = ocrLines(page, index: i)
            } else if let selection = page.selection(for: box) {
                let reader = LineReader(page: page, index: i, text: text, box: box)
                result = selection.selectionsByLine().compactMap(reader.line)
            }
            if pictures { result += Self.pictures(on: page, index: i, box: box, text: result) }
            pages.append(readingOrder(result))
            let span = progress.upperBound - progress.lowerBound
            ctx.progress(progress.lowerBound + span * Double(i + 1) / Double(doc.pageCount))
        }
        return pages
    }

    /// Reads one line of a page: styled runs, split into cells wherever a gap is wider than a couple of spaces.
    private final class LineReader {
        let page: PDFPage
        let index: Int
        let text: NSString
        let box: CGRect
        let attributed: NSAttributedString?
        let links: [(rect: CGRect, url: String)]
        private var styles: [String: (bold: Bool, italic: Bool, mono: Bool)] = [:]

        init(page: PDFPage, index: Int, text: NSString, box: CGRect) {
            self.page = page
            self.index = index
            self.text = text
            self.box = box
            let a = page.attributedString
            attributed = a?.length == text.length ? a : nil
            links = page.annotations.compactMap { annotation in
                guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url else { return nil }
                return (annotation.bounds.insetBy(dx: 0, dy: -1), url.absoluteString)
            }
        }

        private func style(of font: NSFont) -> (bold: Bool, italic: Bool, mono: Bool) {
            if let known = styles[font.fontName] { return known }
            let name = font.fontName.lowercased()
            let traits = font.fontDescriptor.symbolicTraits
            let result = (
                bold: traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) },
                italic: traits.contains(.italic) || name.contains("italic") || name.contains("oblique"),
                mono: traits.contains(.monoSpace) || ["mono", "courier", "menlo", "consolas", "monaco", "inconsolata"].contains { name.contains($0) }
            )
            styles[font.fontName] = result
            return result
        }

        func line(_ selection: PDFSelection) -> Line? {
            var cells: [Cell] = []
            var runs: [Inline] = []
            var cellMin: CGFloat = 0, cellMax: CGFloat = 0
            var previousMax: CGFloat?
            var pendingSpace = false
            var words: [ClosedRange<CGFloat>] = []
            var newWord = true
            var sizes: [CGFloat: Int] = [:]
            var letters = 0, bold = 0, italic = 0, mono = 0

            func add(_ s: String, _ run: Inline) {
                if let last = runs.last, last.sameStyle(as: run) {
                    runs[runs.count - 1].text += s
                } else {
                    var piece = run
                    piece.text = s
                    runs.append(piece)
                }
            }
            func addSpace(before next: Inline) {
                // A space between two styles takes the plain style, so "**bold** word" stays tidy.
                guard let last = runs.last else { return }
                add(" ", last.sameStyle(as: next) ? next : Inline(text: "", link: last.link == next.link ? next.link : nil))
            }
            func closeCell() {
                if !runs.isEmpty { cells.append(Cell(runs: runs, minX: cellMin, maxX: cellMax)) }
                runs = []
            }

            for r in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: r, on: page)
                guard range.location != NSNotFound else { continue }
                var i = range.location
                let end = min(text.length, range.location + range.length)
                while i < end {
                    let composed = text.rangeOfComposedCharacterSequence(at: i)
                    i = composed.location + composed.length
                    let raw = text.substring(with: composed)
                    let ch = PDFEngine.ligatures[raw] ?? raw
                    if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0xFFFC }) {
                        if !runs.isEmpty { pendingSpace = true }
                        continue
                    }
                    // characterBounds(at:) skips line breaks when it counts, so its positions drift away
                    // from page.string. A one-character selection stays lined up.
                    let b = page.selection(for: composed)?.bounds(for: page) ?? .zero
                    var run = Inline(text: "")
                    var size = max(4, b.height * 0.8)
                    if let attributed, composed.location < attributed.length,
                       let font = attributed.attribute(.font, at: composed.location, effectiveRange: nil) as? NSFont {
                        let s = style(of: font)
                        run.bold = s.bold
                        run.italic = s.italic
                        run.code = s.mono
                        size = font.pointSize
                    }
                    let center = CGPoint(x: b.midX, y: b.midY)
                    run.link = links.first { $0.rect.contains(center) }?.url

                    if b.width > 0 || b.height > 0 {
                        if let previous = previousMax, !runs.isEmpty {
                            let gap = b.minX - previous
                            if gap > max(size * 1.1, 7) {
                                closeCell()
                                newWord = true
                            } else if pendingSpace || gap > size * 0.2 || gap < -size {
                                addSpace(before: run)
                                newWord = true
                            }
                        } else if pendingSpace {
                            addSpace(before: run)
                            newWord = true
                        }
                        if runs.isEmpty {
                            cellMin = b.minX
                            cellMax = b.maxX
                        }
                        cellMax = max(cellMax, b.maxX)
                        previousMax = b.maxX
                        if newWord || words.isEmpty {
                            words.append(b.minX...max(b.minX, b.maxX))
                        } else if let last = words.last {
                            words[words.count - 1] = min(last.lowerBound, b.minX)...max(last.upperBound, b.maxX)
                        }
                        newWord = false
                    } else if pendingSpace {
                        addSpace(before: run)
                        newWord = true
                    }
                    pendingSpace = false
                    add(ch, run)
                    letters += 1
                    if run.bold { bold += 1 }
                    if run.italic { italic += 1 }
                    if run.code { mono += 1 }
                    sizes[(size * 2).rounded() / 2, default: 0] += 1
                }
            }
            closeCell()
            guard letters > 0, !cells.isEmpty else { return nil }

            let bounds = selection.bounds(for: page)
            var line = Line(cells: cells, minX: cells.map(\.minX).min() ?? bounds.minX, maxX: cells.map(\.maxX).max() ?? bounds.maxX,
                            top: bounds.maxY, bottom: bounds.minY,
                            size: sizes.max { $0.value < $1.value }?.key ?? max(4, bounds.height * 0.8),
                            page: index, box: box)
            if line.maxX <= line.minX { line.minX = bounds.minX; line.maxX = bounds.maxX }
            line.bold = bold == letters
            line.italic = italic == letters
            line.mono = mono == letters
            line.words = words
            // A marker split from its text by a tab is still one list item, not two cells.
            if line.cells.count >= 2, line.cells[0].text.range(of: PDFEngine.markerOnly, options: .regularExpression) != nil {
                let first = line.cells.removeFirst()
                line.cells[0].runs = first.runs + [Inline(text: " ")] + line.cells[0].runs
                line.cells[0].minX = first.minX
            }
            return line
        }
    }

    /// Typographic ligatures that PDFs often keep as one character, so "Office" doesn't come out as "Oﬃce".
    static let ligatures = ["\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
                            "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st"]

    static func expandLigatures(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) }) else { return text }
        return ligatures.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// A line that's only a divider, like "* * *" or "———".
    static func isRule(_ text: String) -> Bool {
        text.range(of: #"^[\s*\-_•·=~—–]+$"#, options: .regularExpression) != nil && text.filter { !$0.isWhitespace }.count >= 3
    }

    /// Drops what repeats in the margins: page numbers, running headers and footers, and header logos.
    static func body(_ pages: [[Line]]) -> [[Line]] {
        func key(_ l: Line) -> String? {
            let h = l.box.height
            let zone = l.top - l.box.minY > h * 0.92 ? "top" : l.bottom - l.box.minY < h * 0.08 ? "bottom" : nil
            guard let zone else { return nil }
            if l.picture != nil { return "\(zone) picture \(Int(l.minX / 4)) \(Int(l.bottom / 4)) \(Int(l.maxX / 4)) \(Int(l.top / 4))" }
            return "\(zone) " + l.text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        }
        var counts: [String: Int] = [:]
        for lines in pages { for k in Set(lines.compactMap(key)) { counts[k, default: 0] += 1 } }
        let repeated = pages.count >= 3 ? Set(counts.filter { $0.value >= max(3, (pages.count + 1) / 2) }.keys) : []
        return pages.map { lines in
            lines.filter { l in
                guard let k = key(l) else { return true }
                if repeated.contains(k) { return false }
                return l.picture != nil || l.text.range(of: #"^(page\s*)?\d{1,4}(\s*(of|/)\s*\d{1,4})?$"#,
                                                         options: [.regularExpression, .caseInsensitive]) == nil
            }
        }
    }

    static let markerOnly = #"^([•◦▪‣●○■□➢►–\-\*]|\d{1,3}[.)]|[a-zA-Z][.)])$"#
    static let bulletPattern = #"^([•◦▪‣●○■□➢►–\-\*])\s+"#
    static let numberPattern = #"^(\d{1,3})[.)]\s+"#

    /// Top to bottom, and column by column where the text sits in columns. PDFKit's own order mixes columns
    /// whenever their paragraphs sit side by side, so the order is rebuilt from positions.
    private static func readingOrder(_ lines: [Line]) -> [Line] {
        let topDown: (Line, Line) -> Bool = { abs($0.top - $1.top) > 2 ? $0.top > $1.top : $0.minX < $1.minX }
        let gutters = Self.gutters(lines)
        func column(_ l: Line) -> Int? {
            for (i, gutter) in gutters.enumerated() {
                if l.maxX <= gutter.lowerBound + 1 { return i }
                if l.minX < gutter.upperBound - 1 { return nil }
            }
            return gutters.count
        }
        var out: [Line] = []
        var segment = Array(repeating: [Line](), count: gutters.count + 1)
        // Something that spans the columns (a title, a wide picture) closes the columns above it.
        func flush() {
            for (c, members) in segment.enumerated() {
                out += mergedBaselines(members).sorted(by: topDown).map { var l = $0; l.column = c; return l }
            }
            segment = Array(repeating: [], count: gutters.count + 1)
        }
        for line in lines.sorted(by: topDown) {
            if let c = column(line) {
                segment[c].append(line)
            } else {
                flush()
                var spanning = line
                spanning.column = nil
                out.append(spanning)
            }
        }
        flush()
        return out
    }

    /// The gaps between text columns: strips of the page that lines of prose on both sides stop short of.
    private static func gutters(_ lines: [Line]) -> [ClosedRange<CGFloat>] {
        let text = lines.filter { $0.picture == nil }
        guard let left = text.map(\.minX).min(), let right = text.map(\.maxX).max(), right - left > 200 else { return [] }
        let width = right - left
        // Prose fills most of a column but not the page; table cells and headings are too short to count.
        let prose = text.filter { l in
            let w = l.maxX - l.minX
            return l.text.count >= 20 && w >= width * 0.2 && w <= width * 0.62
        }
        guard prose.count >= 6 else { return [] }
        var bands: [ClosedRange<CGFloat>] = []
        let spans = prose.map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
        var reach = spans[0].1
        for (a, b) in spans.dropFirst() {
            if a - reach >= 8 { bands.append(reach...a) }
            reach = max(reach, b)
        }
        // A real gutter has a column of prose on each side, next to each other on the page.
        return bands.filter { band in
            let before = prose.filter { $0.maxX <= band.lowerBound + 0.5 }
            let after = prose.filter { $0.minX >= band.upperBound - 0.5 }
            guard before.count >= 3, after.count >= 3,
                  let beforeTop = before.map(\.top).max(), let beforeBottom = before.map(\.bottom).min(),
                  let afterTop = after.map(\.top).max(), let afterBottom = after.map(\.bottom).min() else { return false }
            return min(beforeTop, afterTop) - max(beforeBottom, afterBottom) > 0
        }
    }

    /// Pieces of one visual row that PDFKit reports as separate lines (table cells, a marker apart from its text).
    private static func mergedBaselines(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines.sorted(by: { $0.minX < $1.minX }) {
            if line.picture == nil, let i = out.firstIndex(where: { other in
                other.picture == nil && other.page == line.page
                    && abs(other.top - line.top) < 2.5 && abs(other.bottom - line.bottom) < 2.5
                    && (line.minX >= other.maxX - 1 || line.maxX <= other.minX + 1)
                    // Two long lines side by side are text columns, not a table row.
                    && (other.text.count < 40 || line.text.count < 40)
            }) {
                var merged = out[i]
                merged.cells = (merged.cells + line.cells).sorted { $0.minX < $1.minX }
                merged.words = (merged.words + line.words).sorted { $0.lowerBound < $1.lowerBound }
                merged.minX = min(merged.minX, line.minX)
                merged.maxX = max(merged.maxX, line.maxX)
                merged.bold = merged.bold && line.bold
                merged.italic = merged.italic && line.italic
                merged.mono = merged.mono && line.mono
                if line.text.count > merged.text.count - line.text.count { merged.size = line.size }
                out[i] = merged
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Reads a scanned page with Vision.
    static func ocrLines(_ page: PDFPage, index: Int) -> [Line] {
        guard let image = render(page, scale: 2.5) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ocrLanguages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width
        let h = rotated ? box.width : box.height
        let space = CGRect(x: 0, y: 0, width: w, height: h)
        return (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = PDFEngine.expandLigatures(candidate.string)
            let r = observation.boundingBox
            let rect = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
            // Where each word sits, so wide gaps split a row into table cells like they do for real text.
            var words: [(text: String, span: ClosedRange<CGFloat>)] = []
            var cursor = text.startIndex
            while let start = text[cursor...].firstIndex(where: { !$0.isWhitespace }) {
                let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                let b = (try? candidate.boundingBox(for: start..<end))?.boundingBox
                let span = b.map { $0.minX * w...max($0.minX, $0.maxX) * w } ?? rect.minX...rect.maxX
                words.append((String(text[start..<end]), span))
                cursor = end
            }
            guard !words.isEmpty else { return nil }
            var cells: [Cell] = []
            for word in words {
                if var last = cells.last, word.span.lowerBound - last.maxX <= max(rect.height * 1.1, 7) {
                    last.runs[0].text += " " + word.text
                    last.maxX = max(last.maxX, word.span.upperBound)
                    cells[cells.count - 1] = last
                } else {
                    cells.append(Cell(runs: [Inline(text: word.text)], minX: word.span.lowerBound, maxX: word.span.upperBound))
                }
            }
            var line = Line(cells: cells, minX: rect.minX, maxX: rect.maxX, top: rect.maxY, bottom: rect.minY,
                            size: max(6, rect.height * 0.78), page: index, box: space)
            line.words = words.map(\.span)
            return line
        }
    }

    /// The languages scans are read in: the Mac's preferred languages that Vision knows, then English.
    /// Vision can detect the language itself, but that can take a minute to warm up.
    private static let ocrLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        var out: [String] = []
        for preferred in Locale.preferredLanguages + ["en-US"] {
            let base = String(preferred.prefix { $0 != "-" && $0 != "_" })
            if let match = supported.first(where: { $0 == preferred }) ?? supported.first(where: { $0.hasPrefix(base) }),
               !out.contains(match) {
                out.append(match)
            }
        }
        return out.isEmpty ? ["en-US"] : out
    }()

    // MARK: Pictures

    /// Pictures on the page: raster images, plus vector art drawn as a form with no text in it (logos, diagrams).
    /// Each is cut out of a render of the page so masks and colour spaces come out right.
    private static func pictures(on page: PDFPage, index: Int, box: CGRect, text: [Line]) -> [Line] {
        guard page.rotation % 360 == 0, let ref = page.pageRef else { return [] }
        let found = PictureFinder().rects(on: ref)
        func usable(_ rect: CGRect) -> CGRect? {
            let r = rect.intersection(box)
            guard !r.isNull, r.width >= 24, r.height >= 24, r.width * r.height < box.width * box.height * 0.8 else { return nil }
            return r
        }
        let textBoxes = text.map { CGRect(x: $0.minX, y: $0.bottom, width: max(1, $0.maxX - $0.minX), height: max(1, $0.height)) }
        let art = found.forms.compactMap(usable).filter { r in !textBoxes.contains { $0.intersects(r.insetBy(dx: 2, dy: 2)) } }
        // Biggest first; skip repeats and pictures that sit inside another one.
        var kept: [CGRect] = []
        for rect in (found.images.compactMap(usable) + art).sorted(by: { $0.width * $0.height > $1.width * $1.height })
            where !kept.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(rect) }) {
            kept.append(rect)
        }
        return kept.compactMap { rect in
            guard let picture = cut(page, rect: rect, box: box) else { return nil }
            var line = Line(cells: [], minX: rect.minX, maxX: rect.maxX, top: rect.maxY, bottom: rect.minY, size: 0, page: index, box: box)
            line.picture = picture
            return line
        }
    }

    private static func cut(_ page: PDFPage, rect: CGRect, box: CGRect, scale: CGFloat = 2) -> (data: Data, ext: String)? {
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }
        // Photos as JPEG, small art as PNG.
        let jpeg = w * h > 250_000
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
                              : rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, jpeg ? "jpg" : "png")
    }

    /// Walks a page's drawing commands and notes where image XObjects land, following form XObjects.
    private final class PictureFinder {
        private var ctm = CGAffineTransform.identity
        private var saved: [CGAffineTransform] = []
        private var images: [CGRect] = []
        private var forms: [CGRect] = []
        private var depth = 0
        private let table: CGPDFOperatorTableRef?

        init() {
            table = CGPDFOperatorTableCreate()
            guard let table else { return }
            CGPDFOperatorTableSetCallback(table, "q") { _, info in PictureFinder.from(info)?.save() }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in PictureFinder.from(info)?.restore() }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in PictureFinder.from(info)?.concat(scanner) }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in PictureFinder.from(info)?.draw(scanner) }
        }

        deinit {
            if let table { CGPDFOperatorTableRelease(table) }
        }

        static func from(_ info: UnsafeMutableRawPointer?) -> PictureFinder? {
            info.map { Unmanaged<PictureFinder>.fromOpaque($0).takeUnretainedValue() }
        }

        func rects(on page: CGPDFPage) -> (images: [CGRect], forms: [CGRect]) {
            let stream = CGPDFContentStreamCreateWithPage(page)
            scan(stream)
            CGPDFContentStreamRelease(stream)
            return (images, forms)
        }

        private func scan(_ stream: CGPDFContentStreamRef) {
            guard let table else { return }
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
        }

        private func save() { saved.append(ctm) }

        private func restore() { if let last = saved.popLast() { ctm = last } }

        private func concat(_ scanner: CGPDFScannerRef) {
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
            ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(ctm)
        }

        private func draw(_ scanner: CGPDFScannerRef) {
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePointer), let name = namePointer else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtypePointer: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtypePointer), let subtypePointer else { return }
            switch String(cString: subtypePointer) {
            case "Image":
                images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm))
            case "Form":
                guard depth < 6 else { return }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { _ = CGPDFArrayGetNumber(array, i, &v[i]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var bbox: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "BBox", &bbox), let bbox, CGPDFArrayGetCount(bbox) == 4 {
                    var v = [CGPDFReal](repeating: 0, count: 4)
                    for i in 0..<4 { _ = CGPDFArrayGetNumber(bbox, i, &v[i]) }
                    let rect = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
                    forms.append(rect.applying(matrix.concatenating(ctm)))
                }
                var resources: CGPDFDictionaryRef?
                if !CGPDFDictionaryGetDictionary(dict, "Resources", &resources) { resources = nil }
                let outer = ctm
                ctm = matrix.concatenating(ctm)
                depth += 1
                let form = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, content)
                scan(form)
                CGPDFContentStreamRelease(form)
                depth -= 1
                ctm = outer
            default:
                break
            }
        }
    }

    // MARK: Structure

    /// Rebuilds headings, paragraphs, lists, quotes, code, tables and pictures from where things sit on the page.
    static func model(_ src: URL, ctx: JobContext) throws -> DocModel {
        let doc = try open(src)
        let pages = body(try lines(doc, ctx: ctx, pictures: true))
        let textLines = pages.flatMap { $0 }.filter { $0.picture == nil }
        var title = Output.stem(src)
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }

        // Body size: the size most of the text is set in. Headings are the bigger sizes, largest first.
        var weights: [CGFloat: Int] = [:]
        for l in textLines { weights[(l.size * 2).rounded() / 2, default: 0] += l.text.count }
        let body = weights.max { $0.value < $1.value }?.key ?? 11
        let headingSizes = Array(Set(textLines.filter { $0.size >= body * 1.15 && $0.text.count < 140 }
            .map { ($0.size * 2).rounded() / 2 })).sorted(by: >)
        func level(_ l: Line) -> Int {
            guard l.text.count < 140, !l.mono else { return 0 }
            let s = (l.size * 2).rounded() / 2
            if s >= body * 1.15, let i = headingSizes.firstIndex(of: s) { return min(3, i + 1) }
            return 0
        }

        // Each text column's left edge and where its lines usually end. Lines that span the columns use the whole page.
        var edges: [String: (left: CGFloat, right: CGFloat)] = [:]
        func spot(_ page: Int, _ column: Int?) -> String { "\(page) \(column.map(String.init) ?? "all")" }
        func measure(_ lines: [Line]) -> (left: CGFloat, right: CGFloat)? {
            guard let left = lines.map(\.minX).min() else { return nil }
            // Most lines, not the widest: one overlong URL shouldn't make every other line look short.
            let ends = lines.map(\.maxX).sorted()
            return (left, ends[min(ends.count - 1, Int(Double(ends.count) * 0.9))])
        }
        // A page with only a few lines can't say where its lines end, so it borrows the whole document's edges.
        var everywhere: [Int?: [Line]] = [:]
        for (p, lines) in pages.enumerated() {
            let wide = lines.filter { $0.picture == nil && $0.text.count >= 8 }
            if wide.count >= 5 { edges[spot(p, nil)] = measure(wide) }
            for (column, members) in Dictionary(grouping: wide, by: \.column) {
                everywhere[column, default: []] += members
                if column != nil, members.count >= 5 { edges[spot(p, column)] = measure(members) }
            }
        }
        let documentEdges = everywhere.compactMapValues(measure)
        let multiColumnPages = Set(pages.indices.filter { p in pages[p].contains { $0.column != 0 } })
        let fallback = (left: textLines.map(\.minX).min() ?? 0, right: textLines.map(\.maxX).max() ?? 612)
        func edgeOf(_ l: Line) -> (left: CGFloat, right: CGFloat) {
            edges[spot(l.page, l.column)] ?? documentEdges[l.column] ?? edges[spot(l.page, nil)] ?? fallback
        }

        var blocks: [Block] = []
        var alignments: [Int: TextAlign] = [:]
        var paragraph: [Line] = []
        var paragraphKind = 0
        var listItem: (ordered: Bool, depth: Int, number: Int)?
        var itemTextX: CGFloat?          // where a list item's text starts, after its marker
        var markerLength = 0
        var markers: [CGFloat] = []      // x of each open list level's marker
        var hardBreaks: Set<Int> = []    // paragraph lines that start after a deliberate line break
        var code: [Line] = []
        var table: [Line] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            defer { paragraph = []; listItem = nil; itemTextX = nil; markerLength = 0; hardBreaks = [] }
            var runs: [Inline] = []
            for (i, line) in paragraph.enumerated() {
                var lineRuns = line.runs
                if i == 0 && markerLength > 0 { lineRuns = dropPrefix(lineRuns, markerLength) }
                if hardBreaks.contains(i) {
                    runs.append(Inline(text: "\n"))
                } else if let last = runs.last, last.text.hasSuffix("-"), let next = Inlines.plain(lineRuns).first {
                    // A word hyphenated at the end of a line joins back up; "USB-" + "C" keeps its hyphen.
                    if next.isLowercase { runs[runs.count - 1].text.removeLast() }
                } else if !runs.isEmpty {
                    runs.append(Inline(text: " "))
                }
                runs += lineRuns
            }
            let normalized = Inlines.normalized(runs)
            guard !normalized.isEmpty else { return }
            let first = paragraph[0]
            let edge = edgeOf(first)
            // Short documents may have no line that reaches the right margin. Margins are usually even, so a
            // single column is taken to end as far from the right as it starts from the left.
            let singleColumn = first.column == nil || (first.column == 0 && !multiColumnPages.contains(first.page))
            let mirror = first.box.maxX - (edge.left - first.box.minX)
            let centerRight = singleColumn ? max(edge.right, mirror) : edge.right
            let centered = paragraph.allSatisfy { l in
                let left = l.minX - edge.left, right = centerRight - l.maxX
                return left > 20 && abs(left - right) < 8
            }
            let indented = !centered && paragraph.allSatisfy { $0.minX - edge.left >= 12 }
            if centered { alignments[blocks.count] = .center }
            if paragraphKind > 0 {
                blocks.append(.heading(paragraphKind, Inlines.merged(normalized.map { var r = $0; r.bold = false; return r })))
            } else if let item = listItem {
                blocks.append(.listItem(ordered: item.ordered, depth: item.depth, number: item.number, normalized))
            } else if indented {
                blocks.append(.quote(Inlines.merged(normalized.map { var r = $0; r.italic = false; return r })))
            } else {
                blocks.append(.paragraph(normalized))
            }
        }

        func flushCode() {
            guard !code.isEmpty else { return }
            let left = code.map(\.minX).min() ?? 0
            let charWidth = max(3, (code[0].size) * 0.6)
            var text: [String] = []
            for (i, line) in code.enumerated() {
                if i > 0, code[i - 1].bottom - line.top > line.height * 0.9 { text.append("") }
                text.append(String(repeating: " ", count: max(0, Int(((line.minX - left) / charWidth).rounded()))) + line.text)
            }
            blocks.append(.code(text.joined(separator: "\n")))
            code = []
        }

        func flushTable() {
            guard !table.isEmpty else { return }
            let rows = table
            table = []
            guard rows.count >= 2 else {
                // One row on its own is just a line of text.
                for line in rows { handle(line, tables: false) }
                return
            }
            let anchors = columnAnchors(rows.flatMap { $0.cells.map(\.minX) })
            var cells: [[[Inline]]] = rows.map { line in
                var row = Array(repeating: [Inline](), count: max(1, anchors.count))
                for cell in line.cells {
                    let c = anchors.lastIndex { $0 <= cell.minX + 8 } ?? 0
                    if !row[c].isEmpty { row[c].append(Inline(text: " ")) }
                    row[c] += cell.runs
                }
                return row.map(Inlines.normalized)
            }
            // A header row that's bold all over is just the header.
            let words = cells[0].flatMap { $0 }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !words.isEmpty && words.allSatisfy(\.bold) {
                cells[0] = cells[0].map { $0.map { var r = $0; r.bold = false; return r } }
            }
            blocks.append(.table(cells))
        }

        func flushAll() {
            // A lone table row goes back through as text, so the table goes first.
            flushTable()
            flushParagraph()
            flushCode()
        }

        func handle(_ line: Line, tables: Bool = true) {
            let text = line.text
            if isRule(text) {
                flushAll()
                blocks.append(.rule)
                markers = []
                return
            }
            if line.mono {
                flushTable()
                flushParagraph()
                code.append(line)
                return
            }
            flushCode()
            if tables, line.cells.count >= 2,
               line.cells.map(\.text.count).reduce(0, +) / line.cells.count <= 40 {
                if let last = table.last, last.page != line.page || last.bottom - line.top > max(last.height, line.height) * 2.5 {
                    flushTable()
                }
                flushParagraph()
                table.append(line)
                return
            }
            flushTable()

            let edge = edgeOf(line)
            var startsItem: (ordered: Bool, number: Int, marker: Int)?
            if let m = text.range(of: bulletPattern, options: .regularExpression) {
                startsItem = (false, 0, text.distance(from: text.startIndex, to: m.upperBound))
            } else if let m = text.range(of: numberPattern, options: .regularExpression) {
                startsItem = (true, Int(text[m].filter(\.isNumber)) ?? 1, text.distance(from: text.startIndex, to: m.upperBound))
            }
            let kind = level(line)

            var newParagraph = paragraph.isEmpty || kind != paragraphKind || startsItem != nil
            var hardBreak = false
            if let last = paragraph.last, !newParagraph {
                let gap = last.bottom - line.top
                let lead = max(last.height, line.height)
                // The next line's first word would have fit at the end of this one, so the break was made on purpose.
                let right = listItem == nil && paragraph[0].minX - edge.left >= 12
                    ? max(line.maxX, paragraph.map(\.maxX).max() ?? 0)   // indented both sides, like a quote
                    : edge.right
                let firstWord = line.words.first.map { $0.upperBound - $0.lowerBound } ?? .greatestFiniteMagnitude
                let fits = last.maxX + last.size * 0.25 + firstWord < right - 2
                if last.page != line.page || last.column != line.column {
                    // Carry a sentence over to the next page or column.
                    newParagraph = !(text.first?.isLowercase ?? false)
                } else if gap > lead * 0.75 || gap < -lead {
                    newParagraph = true
                } else if abs(last.size - line.size) > 0.6 {
                    newParagraph = true
                } else if (last.italic != line.italic || last.bold != line.bold) && abs(line.minX - last.minX) > 4 {
                    newParagraph = true
                } else if line.minX - last.minX > 14 && listItem == nil {
                    newParagraph = true
                } else if let x = itemTextX, line.minX < x - 4 {
                    // A list item's own lines line up with its text; a line back at the marker or the margin is new.
                    newParagraph = true
                } else if fits, kind == 0 {
                    if let end = last.text.last, ".!?:”\"".contains(end) {
                        newParagraph = true
                    } else {
                        hardBreak = true
                    }
                }
            }
            if newParagraph {
                flushParagraph()
                paragraphKind = kind
                if let item = startsItem, kind == 0 {
                    // Nesting follows where each marker sits. Bullets and numbers at one level can sit a few
                    // points apart, since numbers line up on their right edge.
                    while let top = markers.last, line.minX < top - 8 { markers.removeLast() }
                    if markers.last.map({ line.minX > $0 + 8 }) ?? true { markers.append(line.minX) }
                    listItem = (item.ordered, markers.count - 1, item.number)
                    itemTextX = line.words.count >= 2 ? line.words[1].lowerBound : nil
                    markerLength = item.marker
                } else if line.minX - edge.left < 12 {
                    markers = []
                }
            } else if hardBreak {
                hardBreaks.insert(paragraph.count)
            }
            paragraph.append(line)
        }

        for lines in pages {
            for line in lines {
                if let picture = line.picture {
                    flushAll()
                    blocks.append(.image(picture.data, ext: picture.ext, alt: ""))
                } else {
                    handle(line)
                }
            }
        }
        flushAll()
        return DocModel(title: title, blocks: blocks, alignments: alignments)
    }

    private static func dropPrefix(_ runs: [Inline], _ count: Int) -> [Inline] {
        var remaining = count
        var out: [Inline] = []
        for var run in runs {
            if remaining > 0 {
                let n = min(remaining, run.text.count)
                run.text = String(run.text.dropFirst(n))
                remaining -= n
            }
            if !run.text.isEmpty { out.append(run) }
        }
        return out
    }

    /// Column starts shared by several rows.
    private static func columnAnchors(_ xs: [CGFloat], tolerance: CGFloat = 12) -> [CGFloat] {
        var out: [CGFloat] = []
        for x in xs.sorted() {
            if let last = out.last, x - last < tolerance { continue }
            out.append(x)
        }
        return out
    }

    // MARK: Tables for spreadsheets

    /// Rows and columns: lines with several cells line up under shared column edges; single lines go in column A.
    static func tableRows(_ src: URL, ctx: JobContext) throws -> [[String]] {
        let doc = try open(src)
        let pages = body(try lines(doc, ctx: ctx))
        var rows: [[String]] = []
        for pageLines in pages {
            let anchors = columnAnchors(pageLines.filter { $0.cells.count >= 2 }.flatMap { $0.cells.map(\.minX) })
            for line in pageLines where line.picture == nil && !isRule(line.text) {
                guard line.cells.count >= 2, anchors.count >= 2 else {
                    rows.append([line.text])
                    continue
                }
                var row = Array(repeating: "", count: anchors.count)
                for cell in line.cells {
                    let c = anchors.lastIndex { $0 <= cell.minX + 8 } ?? 0
                    row[c] = row[c].isEmpty ? cell.text : row[c] + " " + cell.text
                }
                while row.count > 1 && row.last == "" { row.removeLast() }
                rows.append(row)
            }
            if !rows.isEmpty, pages.count > 1 { rows.append([]) }
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }
}
