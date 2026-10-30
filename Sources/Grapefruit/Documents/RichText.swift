import AppKit

/// NSAttributedString in and out: how Word, RTF, PDF and image outputs get made.
enum RichText {
    // House style for documents Grapefruit lays out itself (Markdown, text, HTML, EPUB sources).
    static let bodySize: CGFloat = 11.5
    static let family = "Helvetica Neue"
    static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1)
    static let quiet = NSColor(srgbRed: 0.40, green: 0.40, blue: 0.38, alpha: 1)
    static let codeBackground = NSColor(srgbRed: 0.955, green: 0.952, blue: 0.935, alpha: 1)
    static let accent = NSColor(srgbRed: 0.79, green: 0.29, blue: 0.09, alpha: 1)

    /// The house font, or `requested` (a family name from Word or RTF) when this Mac has it.
    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, family requested: String? = nil) -> NSFont {
        if let requested, !requested.isEmpty, requested != family {
            let manager = NSFontManager.shared
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            if let exact = manager.font(withFamily: requested, traits: traits, weight: 5, size: size) { return exact }
            if var plain = manager.font(withFamily: requested, traits: [], weight: 5, size: size) ?? NSFont(name: requested, size: size) {
                if bold { plain = manager.convert(plain, toHaveTrait: .boldFontMask) }
                if italic { plain = manager.convert(plain, toHaveTrait: .italicFontMask) }
                return plain
            }
        }
        let base = NSFont(name: bold ? "\(family) Bold" : family, size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard italic else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    private static func nsAlignment(_ align: TextAlign?) -> NSTextAlignment? {
        switch align {
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .left: .left
        case nil: nil
        }
    }

    static func mono(size: CGFloat) -> NSFont {
        NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Model → attributed

    static func attributed(_ doc: DocModel, contentWidth: CGFloat = 468) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lists: [Int: NSTextList] = [:]

        func paragraphStyle(spacingBefore: CGFloat = 0, after: CGFloat = 8, lineHeight: CGFloat = 1.28,
                            indent: CGFloat = 0, firstIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = after
            p.lineHeightMultiple = lineHeight
            p.headIndent = indent
            p.firstLineHeadIndent = firstIndent ?? indent
            return p
        }

        func append(_ runs: [Inline], size: CGFloat, bold: Bool = false, italic: Bool = false,
                    color: NSColor = ink, style: NSParagraphStyle) {
            for run in Inlines.merged(runs) {
                // A source's own typography wins over the house style.
                let runSize = run.size.map { CGFloat($0) } ?? size
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: run.code ? mono(size: runSize * 0.9)
                        : font(size: runSize, bold: bold || run.bold, italic: italic || run.italic, family: run.font),
                    .foregroundColor: run.color.flatMap { RichText.color(hex: $0) } ?? color,
                    .paragraphStyle: style,
                ]
                if run.code { attrs[.backgroundColor] = codeBackground }
                if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, let url = URL(string: link) {
                    attrs[.link] = url
                    attrs[.foregroundColor] = accent
                }
                out.append(NSAttributedString(string: run.text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attrs))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(size: size), .paragraphStyle: style]))
        }

        for (index, block) in doc.blocks.enumerated() {
            if case .listItem = block {} else { lists = [:] }
            let alignment = nsAlignment(doc.alignments[index])
            func aligned(_ style: NSMutableParagraphStyle) -> NSMutableParagraphStyle {
                if let alignment { style.alignment = alignment }
                return style
            }
            switch block {
            case let .heading(level, runs):
                let sizes: [CGFloat] = [24, 18.5, 15, 13, 12, 11.5]
                let size = sizes[min(5, max(0, level - 1))]
                append(runs, size: size, bold: true,
                       style: aligned(paragraphStyle(spacingBefore: level <= 2 ? 16 : 10, after: level <= 2 ? 8 : 5, lineHeight: 1.1)))
            case let .paragraph(runs):
                append(runs, size: bodySize, style: aligned(paragraphStyle()))
            case let .listItem(ordered, depth, number, runs):
                for d in lists.keys where d > depth { lists[d] = nil }
                let list = lists[depth] ?? NSTextList(markerFormat: ordered ? .decimal : (depth % 2 == 0 ? .disc : .circle), options: 0)
                if lists[depth] == nil, ordered, number > 1 { list.startingItemNumber = number }
                lists[depth] = list
                let chain = (0...depth).compactMap { lists[$0] }
                let base = CGFloat(depth) * 18
                let style = paragraphStyle(after: 3, indent: base + 22, firstIndent: base)
                style.textLists = chain
                style.tabStops = [NSTextTab(textAlignment: .right, location: base + 13), NSTextTab(textAlignment: .left, location: base + 22)]
                let marker = ordered ? "\(number > 0 ? number : 1)." : (depth % 2 == 0 ? "•" : "◦")
                out.append(NSAttributedString(string: "\t\(marker)\t", attributes: [
                    .font: font(size: bodySize), .foregroundColor: ink, .paragraphStyle: style,
                ]))
                append(runs, size: bodySize, style: style)
            case let .quote(runs):
                let style = aligned(paragraphStyle(indent: 18))
                append(runs, size: bodySize, italic: true, color: quiet, style: style)
            case let .code(text):
                let style = paragraphStyle(after: 10, lineHeight: 1.15, indent: 10)
                out.append(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", attributes: [
                    .font: mono(size: 9.8), .foregroundColor: ink, .backgroundColor: codeBackground, .paragraphStyle: style,
                ]))
            case .rule:
                let style = paragraphStyle(spacingBefore: 6, after: 12)
                style.alignment = .center
                out.append(NSAttributedString(string: "* * *\n", attributes: [
                    .font: font(size: bodySize), .foregroundColor: quiet, .paragraphStyle: style,
                ]))
            case let .image(data, _, _):
                guard let image = NSImage(data: data), image.size.width > 0 else { continue }
                let attachment = NSTextAttachment()
                let wrapper = FileWrapper(regularFileWithContents: data)
                attachment.fileWrapper = wrapper
                let scale = min(1, contentWidth / image.size.width, 640 / image.size.height)
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                let style = aligned(paragraphStyle(spacingBefore: 4, after: 10, lineHeight: 1))
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
                out.append(piece)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            case let .table(rows):
                let columns = max(1, rows.map(\.count).max() ?? 1)
                let table = NSTextTable()
                table.numberOfColumns = columns
                table.collapsesBorders = true
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                for (r, row) in rows.enumerated() {
                    for c in 0..<columns {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                        block.setWidth(0.6, type: .absoluteValueType, for: .border)
                        block.setBorderColor(NSColor(white: 0.82, alpha: 1))
                        block.setWidth(5, type: .absoluteValueType, for: .padding)
                        if r == 0 && rows.count > 1 { block.backgroundColor = NSColor(white: 0.965, alpha: 1) }
                        let style = paragraphStyle(after: 0, lineHeight: 1.15)
                        style.textBlocks = [block]
                        let runs = c < row.count ? row[c] : []
                        append(runs.isEmpty ? [Inline(text: " ")] : runs, size: bodySize - 1,
                               bold: r == 0 && rows.count > 1, style: style)
                    }
                }
                out.append(NSAttributedString(string: "\n", attributes: [.font: font(size: 6), .paragraphStyle: paragraphStyle(after: 4)]))
            case .pageBreak:
                out.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font(size: bodySize)]))
            }
        }
        return out
    }

    // MARK: Attributed → model

    static func model(_ text: NSAttributedString, title: String) -> DocModel {
        let string = text.string as NSString
        guard string.length > 0 else { return DocModel(title: title, blocks: []) }

        // The most common font size is the body size.
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let f = value as? NSFont { sizes[(f.pointSize * 2).rounded() / 2, default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12

        var blocks: [Block] = []
        var alignments: [Int: TextAlign] = [:]
        var tableRows: [Int: [Int: [Inline]]] = [:]
        var currentTable: NSTextTable?

        func flushTable() {
            guard currentTable != nil else { return }
            let maxRow = tableRows.keys.max() ?? -1
            let maxCol = tableRows.values.flatMap(\.keys).max() ?? -1
            if maxRow >= 0, maxCol >= 0 {
                let rows = (0...maxRow).map { r in (0...maxCol).map { c in Inlines.normalized(tableRows[r]?[c] ?? []) } }
                blocks.append(.table(rows))
            }
            tableRows = [:]
            currentTable = nil
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil

            // Table cells.
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                if currentTable !== cell.table { flushTable(); currentTable = cell.table }
                var runs = tableRows[cell.startingRow]?[cell.startingColumn] ?? []
                if !runs.isEmpty { runs.append(Inline(text: "\n")) }
                runs += inlineRuns(text, range: range, body: body)
                tableRows[cell.startingRow, default: [:]][cell.startingColumn] = runs
                return
            }
            flushTable()
            guard range.length > 0 else { return }

            // Pictures, alone or inside text.
            var segments: [(NSRange, NSTextAttachment?)] = []
            var cursor = range.location
            text.enumerateAttribute(.attachment, in: range) { value, r, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                if r.location > cursor { segments.append((NSRange(location: cursor, length: r.location - cursor), nil)) }
                segments.append((r, attachment))
                cursor = r.location + r.length
            }
            if cursor < range.location + range.length {
                segments.append((NSRange(location: cursor, length: range.location + range.length - cursor), nil))
            }

            for (segment, attachment) in segments {
                if let attachment {
                    if let (data, ext) = imageData(attachment) { blocks.append(.image(data, ext: ext, alt: "")) }
                    continue
                }
                var runs = inlineRuns(text, range: segment, body: body)
                var plain = Inlines.plain(runs)
                guard !plain.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                if let lists = style?.textLists, let list = lists.last {
                    // Drop the marker text ("\t•\t") that list paragraphs carry.
                    if let match = plain.range(of: #"^\t?[^\t]{0,8}\t"#, options: .regularExpression) {
                        let drop = plain.distance(from: plain.startIndex, to: match.upperBound)
                        runs = dropPrefix(runs, count: drop)
                        plain = Inlines.plain(runs)
                    }
                    let ordered = ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .diamond, .box, .check]
                        .contains(list.markerFormat)
                    let itemNumber = text.itemNumber(in: list, at: segment.location)
                    blocks.append(.listItem(ordered: ordered, depth: lists.count - 1, number: itemNumber, Inlines.normalized(runs)))
                    continue
                }

                switch style?.alignment {
                case .center?: alignments[blocks.count] = .center
                case .right?: alignments[blocks.count] = .right
                case .justified?: alignments[blocks.count] = .justified
                default: break
                }
                let level = headingLevel(text, range: segment, style: style, body: body, plain: plain)
                if level > 0 {
                    blocks.append(.heading(level, Inlines.normalized(runs.map { var r = $0; r.bold = false; return r })))
                } else {
                    blocks.append(.paragraph(Inlines.normalized(runs)))
                }
            }
        }
        flushTable()
        return DocModel(title: title, blocks: blocks, alignments: alignments)
    }

    private static func headingLevel(_ text: NSAttributedString, range: NSRange, style: NSParagraphStyle?,
                                     body: CGFloat, plain: String) -> Int {
        if let level = style?.headerLevel, level > 0 { return level }
        guard plain.count < 140, !plain.contains("\n") else { return 0 }
        var largest: CGFloat = 0
        var allBold = true
        text.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let f = value as? NSFont else { return }
            let piece = (text.string as NSString).substring(with: r)
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            largest = max(largest, f.pointSize)
            if !f.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
        }
        let ratio = largest / max(1, body)
        if ratio >= 1.75 { return 1 }
        if ratio >= 1.35 { return 2 }
        if ratio >= 1.12 && allBold { return 3 }
        return 0
    }

    private static func inlineRuns(_ text: NSAttributedString, range: NSRange, body: CGFloat) -> [Inline] {
        var runs: [Inline] = []
        text.enumerateAttributes(in: range) { attrs, r, _ in
            var piece = (text.string as NSString).substring(with: r)
            piece = piece.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
            var run = Inline(text: piece)
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                run.bold = traits.contains(.bold)
                run.italic = traits.contains(.italic)
                run.code = traits.contains(.monoSpace) && !piece.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { run.strike = true }
            if let link = attrs[.link] {
                run.link = (link as? URL)?.absoluteString ?? (link as? String)
            }
            // Keep the source's look for Word output; Markdown and the like drop it.
            if let f = attrs[.font] as? NSFont, !run.code {
                run.font = f.familyName
                run.size = Double(f.pointSize)
            }
            if let c = attrs[.foregroundColor] as? NSColor, run.link == nil, let hex = hex(c), hex != "000000" { run.color = hex }
            if let u = attrs[.underlineStyle] as? Int, u != 0, run.link == nil { run.underline = true }
            runs.append(run)
        }
        return runs
    }

    private static func dropPrefix(_ runs: [Inline], count: Int) -> [Inline] {
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

    private static func imageData(_ attachment: NSTextAttachment) -> (Data, String)? {
        if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents, NSImage(data: data) != nil {
            let ext = ((wrapper.preferredFilename ?? wrapper.filename ?? "") as NSString).pathExtension.lowercased()
            return pngIfNeeded(data, ext: ext)
        }
        if let image = attachment.image, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    /// Keep PNG, JPEG and GIF as they are; turn anything else (TIFF, PDF, HEIC) into PNG.
    private static func pngIfNeeded(_ data: Data, ext: String) -> (Data, String)? {
        if ["png", "jpg", "jpeg", "gif"].contains(ext) { return (data, ext == "jpeg" ? "jpg" : ext) }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    // MARK: Pages

    static var letterSized: Bool { Locale.current.region?.identifier == "US" || Locale.current.measurementSystem == .us }
    static var pageSize: CGSize { letterSized ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }

    /// Lays text out on pages and writes a PDF.
    static func writePDF(_ text: NSAttributedString, to url: URL, pageSize: CGSize = RichText.pageSize,
                         margin: CGFloat = 64, ctx: JobContext? = nil) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
            if containers.count > 5000 { break }
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs
        try ctx?.checkCancelled()

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw JobError.failed("Couldn't create the PDF.")
        }
        for (index, container) in containers.enumerated() {
            let range = layout.glyphRange(for: container)
            if range.length == 0 && index > 0 { continue }
            var box = CGRect(origin: .zero, size: pageSize)
            pdf.beginPage(mediaBox: &box)
            pdf.saveGState()
            pdf.translateBy(x: 0, y: pageSize.height)
            pdf.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: pdf, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            pdf.restoreGState()
            pdf.endPage()
            ctx?.progress(0.3 + 0.6 * Double(index + 1) / Double(containers.count))
        }
        pdf.closePDF()
    }
}
