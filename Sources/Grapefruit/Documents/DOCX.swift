import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Word documents, written and read by hand.
/// AppKit's own Word support drops tables, list numbering, links and pictures, so this maps WordprocessingML to DocModel directly.
enum DOCX {
    static func write(_ doc: DocModel, to url: URL) throws {
        try package(doc).write(to: url, options: .atomic)
    }

    static func package(_ doc: DocModel) throws -> Data {
        let writer = DOCXWriter(doc: doc)
        let document = writer.document()
        let zip = ZipWriter()
        zip.add("[Content_Types].xml", DOCXWriter.contentTypes)
        zip.add("_rels/.rels", DOCXWriter.packageRelationships)
        zip.add("docProps/core.xml", DOCXWriter.core(title: doc.title))
        zip.add("docProps/app.xml", DOCXWriter.app)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", DOCXWriter.styles)
        zip.add("word/numbering.xml", writer.numbering())
        zip.add("word/settings.xml", DOCXWriter.settings)
        zip.add("word/_rels/document.xml.rels", writer.relationships())
        for file in writer.media { zip.add("word/media/\(file.name)", file.data, compress: false) }
        return zip.finish()
    }

    static func read(_ url: URL, title: String) throws -> DocModel {
        let zip: ZipReader
        do { zip = try ZipReader(url: url) } catch {
            throw JobError.failed("This Word file is damaged, or it's an older .doc renamed to .docx.")
        }
        return try DOCXReader(zip: zip, title: title).read()
    }

    // Page geometry in twips (1/20 pt), matching RichText's PDF pages: Letter or A4 with 64 pt margins.
    static var pageTwips: (width: Int, height: Int) { RichText.letterSized ? (12240, 15840) : (11906, 16838) }
    static let marginTwips = 1280
    static var contentTwips: Int { pageTwips.width - 2 * marginTwips }

    /// A picture Word, Pages and browsers can all show: PNG, JPEG or GIF, upright, with its pixel size.
    static func displayable(_ data: Data, ext: String) -> (data: Data, ext: String, width: Int, height: Int)? {
        let e = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
        let head = String(decoding: data.prefix(256), as: UTF8.self)
        if e == "svg" || head.contains("<svg") {
            // Vector art: draw it at twice its size so it stays sharp.
            guard let svg = NSImage(data: data), svg.size.width > 0, svg.size.height > 0 else { return nil }
            let scale = max(2, 800 / max(svg.size.width, svg.size.height))
            let w = Int(svg.size.width * scale), h = Int(svg.size.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return (png, "png", w, h)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if ["png", "jpg", "gif"].contains(e) && orientation == 1 { return (data, e, w, h) }

        // Anything else gets re-encoded with its rotation baked in.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let jpeg = opaque && ["jpg", "heic", "heif", "avif", "webp"].contains(e)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, jpeg ? "jpg" : "png", image.width, image.height)
    }
}

// MARK: - Writing

private final class DOCXWriter {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let relationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    let doc: DocModel
    private(set) var media: [(name: String, data: Data)] = []
    private var rels: [(id: String, type: String, target: String, external: Bool)] = []
    private var linkIds: [String: String] = [:]
    /// One numbering definition per run of list items: each depth's kind and first number.
    private var lists: [[Int: (ordered: Bool, start: Int)]] = []
    private var pictures = 0

    init(doc: DocModel) {
        self.doc = doc
    }

    // MARK: Body

    func document() -> String {
        var body = ""
        var previous: Block?
        for (index, block) in doc.blocks.enumerated() {
            let align = doc.alignments[index]
            switch block {
            case let .heading(level, runs):
                body += paragraph(style: "Heading\(min(6, max(1, level)))", align: align, content: runsXML(runs))
            case let .paragraph(runs):
                body += paragraph(style: nil, align: align, content: runsXML(runs))
            case let .listItem(ordered, depth, number, runs):
                let level = min(8, max(0, depth))
                // A new list starts after other content, or when a level switches between bullets and numbers.
                // Each list's levels start at the numbers the document shows, so a list that resumes keeps counting.
                var continues = false
                if case .listItem = previous { continues = true }
                if !continues || lists.last?[level].map({ $0.ordered != ordered }) == true { lists.append([:]) }
                if lists[lists.count - 1][level] == nil {
                    lists[lists.count - 1][level] = (ordered, ordered ? max(1, number) : 1)
                }
                body += paragraph(style: "ListParagraph", numbering: (lists.count, level), align: align, content: runsXML(runs))
            case let .quote(runs):
                body += paragraph(style: "Quote", align: align, content: runsXML(runs))
            case let .code(text):
                body += paragraph(style: "Code", content: "<w:r>\(textXML(text))</w:r>")
            case .rule:
                body += paragraph(style: "Rule", content: "")
            case let .image(data, ext, alt):
                body += picture(data, ext: ext, alt: alt, align: align)
            case let .table(rows):
                // Word glues neighbouring tables together unless a paragraph sits between them.
                if case .table = previous { body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr></w:p>" }
                body += table(rows)
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
            previous = block
        }
        // The body has to end with a paragraph, never a table.
        if case .table = previous { body += "<w:p/>" }
        if body.isEmpty { body = "<w:p/>" }

        let page = DOCX.pageTwips, m = DOCX.marginTwips
        let section = "<w:sectPr><w:pgSz w:w=\"\(page.width)\" w:h=\"\(page.height)\"/>"
            + "<w:pgMar w:top=\"\(m)\" w:right=\"\(m)\" w:bottom=\"\(m)\" w:left=\"\(m)\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        return Self.header + "<w:document xmlns:w=\"\(Self.w)\" xmlns:r=\"\(Self.relationshipBase)\""
            + " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
            + " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
            + " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<w:body>\(body)\(section)</w:body></w:document>"
    }

    private func paragraph(style: String?, numbering: (id: Int, level: Int)? = nil, align: TextAlign? = nil,
                           spacing: String = "", content: String) -> String {
        var props = ""
        if let style { props += "<w:pStyle w:val=\"\(style)\"/>" }
        if let numbering { props += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.id)\"/></w:numPr>" }
        props += spacing
        if let align, align != .left { props += "<w:jc w:val=\"\(Self.jc(align))\"/>" }
        return "<w:p>" + (props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>") + content + "</w:p>"
    }

    private static func jc(_ align: TextAlign) -> String {
        switch align {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        case .justified: "both"
        }
    }

    // MARK: Runs

    private func runsXML(_ runs: [Inline], bold: Bool = false) -> String {
        var out = ""
        var openLink: String?
        for run in Inlines.merged(runs) {
            if run.link != openLink {
                if openLink != nil { out += "</w:hyperlink>" }
                openLink = nil
                if let link = run.link, let open = hyperlinkStart(link) {
                    out += open
                    openLink = link
                }
            }
            out += runXML(run, bold: bold || run.bold, linked: openLink != nil)
        }
        if openLink != nil { out += "</w:hyperlink>" }
        return out
    }

    private func hyperlinkStart(_ link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            return "<w:hyperlink w:anchor=\"\(String(trimmed.dropFirst()).xmlEscaped)\" w:history=\"1\">"
        }
        let target = trimmed.replacingOccurrences(of: " ", with: "%20")
        let id = linkIds[target] ?? {
            let id = addRelationship(type: "hyperlink", target: target, external: true)
            linkIds[target] = id
            return id
        }()
        return "<w:hyperlink r:id=\"\(id)\" w:history=\"1\">"
    }

    private func runXML(_ run: Inline, bold: Bool, linked: Bool) -> String {
        // Properties in the order the schema wants them.
        var props = ""
        if run.code { props += "<w:rStyle w:val=\"InlineCode\"/>" } else if linked { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
        if let font = run.font, !font.isEmpty, !run.code {
            let f = font.xmlEscaped
            props += "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:eastAsia=\"\(f)\" w:cs=\"\(f)\"/>"
        }
        if bold { props += "<w:b/><w:bCs/>" }
        if run.italic { props += "<w:i/><w:iCs/>" }
        if run.strike { props += "<w:strike/>" }
        if let color = run.color, !linked, color.count == 6, color.allSatisfy(\.isHexDigit) { props += "<w:color w:val=\"\(color)\"/>" }
        if let size = run.size, size > 1, !run.code {
            let halfPoints = Int((size * 2).rounded())
            props += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
        }
        if run.underline && !linked { props += "<w:u w:val=\"single\"/>" }
        return (props.isEmpty ? "<w:r>" : "<w:r><w:rPr>\(props)</w:rPr>") + textXML(run.text) + "</w:r>"
    }

    /// Text with line breaks and tabs as Word elements.
    private func textXML(_ text: String) -> String {
        var out = ""
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            out += "<w:t xml:space=\"preserve\">\(buffer.xmlEscaped)</w:t>"
            buffer = ""
        }
        for ch in text {
            switch ch {
            case "\n", "\r\n", "\r", "\u{2028}", "\u{2029}":
                flush()
                out += "<w:br/>"
            case "\t":
                flush()
                out += "<w:tab/>"
            case "\u{0C}":
                flush()
                out += "<w:br w:type=\"page\"/>"
            default:
                buffer.append(ch)
            }
        }
        flush()
        return out
    }

    // MARK: Tables and pictures

    private func table(_ rows: [[[Inline]]]) -> String {
        let columns = max(1, rows.map(\.count).max() ?? 1)
        let width = DOCX.contentTwips / columns
        let header = rows.count > 1
        // Borders and padding are set on the table too, for apps that ignore table styles.
        let border = ["top", "left", "bottom", "right", "insideH", "insideV"]
            .map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"D5D3CE\"/>" }.joined()
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"GrapefruitTable\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/>"
            + "<w:tblBorders>\(border)</w:tblBorders><w:tblCellMar><w:top w:w=\"80\" w:type=\"dxa\"/><w:left w:w=\"110\" w:type=\"dxa\"/>"
            + "<w:bottom w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"110\" w:type=\"dxa\"/></w:tblCellMar>"
            + "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"1\" w:noVBand=\"1\"/>"
            + "</w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
        for (r, row) in rows.enumerated() {
            let isHeader = header && r == 0
            xml += "<w:tr>" + (isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for c in 0..<columns {
                let runs = c < row.count ? row[c] : []
                let shade = isHeader ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F2EF\"/>" : ""
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shade)</w:tcPr>"
                    + "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr>"
                    + runsXML(runs, bold: isHeader) + "</w:p></w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private func picture(_ data: Data, ext: String, alt: String, align: TextAlign?) -> String {
        guard let image = DOCX.displayable(data, ext: ext) else { return "" }
        pictures += 1
        let name = "image\(pictures).\(image.ext)"
        media.append((name, image.data))
        let id = addRelationship(type: "image", target: "media/\(name)", external: false)

        // 96 dpi, never wider than the text column or taller than 8 inches.
        let emuPerPixel = 9525.0
        let width = Double(image.width) * emuPerPixel, height = Double(image.height) * emuPerPixel
        let scale = min(1, Double(DOCX.contentTwips) * 635 / width, 8 * 914_400 / height)
        let cx = Int(width * scale), cy = Int(height * scale)
        let description = alt.xmlEscaped
        let drawing = "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "<wp:docPr id=\"\(pictures)\" name=\"Picture \(pictures)\" descr=\"\(description)\"/>"
            + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"0\" name=\"\(name)\" descr=\"\(description)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        return paragraph(style: nil, align: align, spacing: "<w:spacing w:before=\"80\" w:after=\"200\" w:line=\"240\" w:lineRule=\"auto\"/>",
                         content: drawing)
    }

    private func addRelationship(type: String, target: String, external: Bool) -> String {
        let id = "rId\(rels.count + 10)"
        rels.append((id, type, target, external))
        return id
    }

    // MARK: Parts

    func relationships() -> String {
        var xml = Self.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(Self.relationshipBase)/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(Self.relationshipBase)/numbering\" Target=\"numbering.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"\(Self.relationshipBase)/settings\" Target=\"settings.xml\"/>"
        for rel in rels {
            xml += "<Relationship Id=\"\(rel.id)\" Type=\"\(Self.relationshipBase)/\(rel.type)\" Target=\"\(rel.target.xmlEscaped)\""
                + (rel.external ? " TargetMode=\"External\"" : "") + "/>"
        }
        return xml + "</Relationships>"
    }

    func numbering() -> String {
        var abstracts = "", instances = ""
        let bullets = ["•", "◦", "▪"]
        for (i, levels) in lists.enumerated() {
            abstracts += "<w:abstractNum w:abstractNumId=\"\(i)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for level in 0..<9 {
                let kind = levels[level] ?? (ordered: false, start: 1)
                // Each level's marker lines up with the text of the level above.
                let indent = "<w:pPr><w:ind w:left=\"\(720 + level * 360)\" w:hanging=\"360\"/></w:pPr>"
                if kind.ordered {
                    abstracts += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"\(kind.start)\"/><w:numFmt w:val=\"decimal\"/>"
                        + "<w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/>\(indent)</w:lvl>"
                } else {
                    abstracts += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/>"
                        + "<w:lvlText w:val=\"\(bullets[level % 3])\"/><w:lvlJc w:val=\"left\"/>\(indent)</w:lvl>"
                }
            }
            abstracts += "</w:abstractNum>"
            instances += "<w:num w:numId=\"\(i + 1)\"><w:abstractNumId w:val=\"\(i)\"/></w:num>"
        }
        return Self.header + "<w:numbering xmlns:w=\"\(Self.w)\">\(abstracts)\(instances)</w:numbering>"
    }

    static let contentTypes = header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="gif" ContentType="image/gif"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """

    static let packageRelationships = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """

    static func core(title: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\""
            + " xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(title.xmlEscaped)</dc:title>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    static let app = header + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Grapefruit</Application></Properties>
        """

    static let settings = header + """
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/>\
        <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>\
        </w:settings>
        """

    /// The house style as Word styles, so the file stays editable: same fonts and sizes as RichText's pages.
    static var styles: String {
        let font = RichText.family.xmlEscaped
        let fonts = "<w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:eastAsia=\"\(font)\" w:cs=\"\(font)\"/>"
        let mono = "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:eastAsia=\"Menlo\" w:cs=\"Menlo\"/>"
        let rule = "D5D3CE"
        var xml = header + "<w:styles xmlns:w=\"\(w)\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr>\(fonts)<w:color w:val=\"1C1C1A\"/><w:sz w:val=\"23\"/><w:szCs w:val=\"23\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"307\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/>"
            + "<w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/>"
            + "<w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/>"
            + "<w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/><w:uiPriority w:val=\"99\"/>"
            + "<w:semiHidden/><w:unhideWhenUsed/></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/>"
            + "<w:uiPriority w:val=\"10\"/><w:qFormat/><w:pPr><w:spacing w:after=\"240\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
            + "<w:rPr><w:b/><w:bCs/><w:sz w:val=\"56\"/><w:szCs w:val=\"56\"/></w:rPr></w:style>"
        let sizes = [48, 37, 30, 26, 24, 23]
        for level in 1...6 {
            let before = level <= 2 ? 320 : 200, after = level <= 2 ? 160 : 100
            xml += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/>"
                + "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"\(after)\" w:line=\"264\" w:lineRule=\"auto\"/>"
                + "<w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
                + "<w:rPr><w:b/><w:bCs/><w:sz w:val=\"\(sizes[level - 1])\"/><w:szCs w:val=\"\(sizes[level - 1])\"/></w:rPr></w:style>"
        }
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:uiPriority w:val=\"34\"/><w:qFormat/><w:pPr><w:spacing w:after=\"60\"/><w:contextualSpacing/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/>"
            + "<w:uiPriority w:val=\"29\"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"E2DED6\"/></w:pBdr>"
            + "<w:ind w:left=\"240\"/></w:pPr><w:rPr><w:i/><w:iCs/><w:color w:val=\"66665F\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F4F3EF\"/><w:spacing w:after=\"200\" w:line=\"252\" w:lineRule=\"auto\"/></w:pPr>"
            + "<w:rPr>\(mono)<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Rule\"><w:name w:val=\"Horizontal Rule\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:next w:val=\"Normal\"/><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"\(rule)\"/></w:pBdr>"
            + "<w:spacing w:before=\"120\" w:after=\"240\"/></w:pPr></w:style>"
            + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:basedOn w:val=\"DefaultParagraphFont\"/>"
            + "<w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/><w:rPr><w:color w:val=\"C94A17\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
            + "<w:style w:type=\"character\" w:styleId=\"InlineCode\"><w:name w:val=\"Inline Code\"/><w:basedOn w:val=\"DefaultParagraphFont\"/>"
            + "<w:rPr>\(mono)<w:sz w:val=\"21\"/><w:szCs w:val=\"21\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F4F3EF\"/></w:rPr></w:style>"
            + "<w:style w:type=\"table\" w:styleId=\"GrapefruitTable\"><w:name w:val=\"Grapefruit Table\"/><w:basedOn w:val=\"TableNormal\"/>"
            + "<w:uiPriority w:val=\"59\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr>"
            + "<w:tblPr><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"]
                .map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"\(rule)\"/>" }.joined()
            + "</w:tblBorders><w:tblCellMar><w:top w:w=\"80\" w:type=\"dxa\"/><w:left w:w=\"110\" w:type=\"dxa\"/>"
            + "<w:bottom w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"110\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
        return xml + "</w:styles>"
    }
}

// MARK: - Reading

private final class DOCXReader {
    private static let mainNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ]
    private static let relationshipNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships",
    ]

    struct RunProps {
        var bold: Bool?
        var italic: Bool?
        var strike: Bool?
        var underline: Bool?
        var hidden: Bool?
        var font: String?
        var size: Double?
        var color: String?

        mutating func apply(_ other: RunProps) {
            bold = other.bold ?? bold
            italic = other.italic ?? italic
            strike = other.strike ?? strike
            underline = other.underline ?? underline
            hidden = other.hidden ?? hidden
            font = other.font ?? font
            size = other.size ?? size
            color = other.color ?? color
        }
    }

    struct ParaProps {
        var numId: String?
        var level: Int?
        var outline: Int?
        var align: TextAlign?
        var bottomBorder: Bool?
        var pageBreakBefore: Bool?

        mutating func apply(_ other: ParaProps) {
            numId = other.numId ?? numId
            level = other.level ?? level
            outline = other.outline ?? outline
            align = other.align ?? align
            bottomBorder = other.bottomBorder ?? bottomBorder
            pageBreakBefore = other.pageBreakBefore ?? pageBreakBefore
        }
    }

    struct Style {
        var name: String
        var basedOn: String?
        var para = ParaProps()
        var run = RunProps()
    }

    struct Field {
        var instruction = ""
        var inResult = false
        var link: String?
    }

    enum Kind {
        case paragraph, heading(Int), list(ordered: Bool, depth: Int, number: Int), quote, code
    }

    enum Piece {
        case text(Inline)
        case image(Data, String, String)
        case pageBreak
        case blocks([(Block, TextAlign?)])
    }

    private let zip: ZipReader
    private let title: String
    private var mainPath = "word/document.xml"
    private var folder = "word"
    private var rels: [String: (target: String, external: Bool)] = [:]
    private var partsByType: [String: String] = [:]
    private var styles: [String: Style] = [:]
    private var defaultParagraphStyle: String?
    private var defaults = RunProps()
    private var abstracts: [String: [Int: (format: String, start: Int)]] = [:]
    private var abstractStyleLinks: [String: String] = [:]
    private var nums: [String: (abstract: String, starts: [Int: Int])] = [:]
    private var counters: [String: [Int: Int]] = [:]
    private var startedNums: Set<String> = []
    private var themeMajor: String?
    private var themeMinor: String?
    private var fields: [Field] = []
    private var nesting = 0

    init(zip: ZipReader, title: String) {
        self.zip = zip
        self.title = title
    }

    func read() throws -> DocModel {
        locateMainPart()
        for rel in relationships(of: mainPath) {
            let path = rel.external ? rel.target : resolve(rel.target, from: folder)
            rels[rel.id] = (path, rel.external)
            if let kind = rel.type.split(separator: "/").last { partsByType[String(kind)] = path }
        }
        loadTheme()
        loadStyles()
        loadNumbering()

        guard let data = try? zip.read(mainPath),
              let xml = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
              let root = xml.rootElement(), let body = Self.child(root, "body") else {
            throw JobError.failed("Couldn't read this Word document.")
        }

        // Page breaks only between content, never doubled.
        var items: [(Block, TextAlign?)] = []
        for item in readBlocks(body) {
            if case .pageBreak = item.0 {
                if items.isEmpty { continue }
                if case .pageBreak = items[items.count - 1].0 { continue }
            }
            items.append(item)
        }
        while let last = items.last, case .pageBreak = last.0 { items.removeLast() }

        var model = DocModel(title: title, blocks: [])
        for (block, align) in items {
            if let align, align != .left { model.alignments[model.blocks.count] = align }
            model.blocks.append(block)
        }
        return model
    }

    // MARK: Package

    private func locateMainPart() {
        if let main = relationships(of: "").first(where: { $0.type.hasSuffix("/officeDocument") }) {
            mainPath = resolve(main.target, from: "")
        }
        folder = (mainPath as NSString).deletingLastPathComponent
    }

    /// The relationships of a part ("" for the package itself).
    private func relationships(of part: String) -> [(id: String, type: String, target: String, external: Bool)] {
        let dir = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        let path = (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
        guard let data = try? zip.read(path), let xml = try? XMLDocument(data: data), let root = xml.rootElement() else { return [] }
        return Self.children(root).compactMap { e in
            guard e.localName == "Relationship", let id = Self.attr(e, "Id"), let target = Self.attr(e, "Target") else { return nil }
            return (id, Self.attr(e, "Type") ?? "", target, Self.attr(e, "TargetMode") == "External")
        }
    }

    private func resolve(_ target: String, from folder: String) -> String {
        let clean = target.removingPercentEncoding ?? target
        if clean.hasPrefix("/") { return String(clean.dropFirst()) }
        return EPUB.join(folder, clean)
    }

    private func part(_ type: String) -> XMLElement? {
        guard let path = partsByType[type], let data = try? zip.read(path),
              let xml = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else { return nil }
        return xml.rootElement()
    }

    private func loadTheme() {
        guard let root = part("theme") else { return }
        for e in Self.descendants(root) where e.localName == "majorFont" || e.localName == "minorFont" {
            let face = Self.child(e, "latin").flatMap { Self.attr($0, "typeface") }.flatMap { $0.isEmpty ? nil : $0 }
            if e.localName == "majorFont" { themeMajor = face } else { themeMinor = face }
        }
    }

    private func loadStyles() {
        guard let root = part("styles") else { return }
        if let defaultsElement = Self.child(root, "docDefaults") {
            defaults = runProps(Self.child(Self.child(defaultsElement, "rPrDefault"), "rPr"))
        }
        for e in Self.children(root) where e.localName == "style" {
            guard let id = Self.attr(e, "styleId") else { continue }
            var style = Style(name: Self.attr(Self.child(e, "name"), "val") ?? id)
            style.basedOn = Self.attr(Self.child(e, "basedOn"), "val")
            style.para = paraProps(Self.child(e, "pPr"))
            style.run = runProps(Self.child(e, "rPr"))
            styles[id] = style
            if Self.attr(e, "type") == "paragraph", let flag = Self.attr(e, "default"), flag == "1" || flag == "true" {
                defaultParagraphStyle = id
            }
        }
    }

    private func loadNumbering() {
        guard let root = part("numbering") else { return }
        for e in Self.children(root) {
            switch e.localName {
            case "abstractNum":
                guard let id = Self.attr(e, "abstractNumId") else { continue }
                var levels: [Int: (format: String, start: Int)] = [:]
                for lvl in Self.children(e) where lvl.localName == "lvl" {
                    let index = Self.attr(lvl, "ilvl").flatMap(Int.init) ?? 0
                    levels[index] = (Self.attr(Self.child(lvl, "numFmt"), "val") ?? "decimal",
                                     Self.attr(Self.child(lvl, "start"), "val").flatMap(Int.init) ?? 1)
                }
                abstracts[id] = levels
                if let link = Self.attr(Self.child(e, "numStyleLink"), "val") { abstractStyleLinks[id] = link }
            case "num":
                guard let id = Self.attr(e, "numId"), let abstract = Self.attr(Self.child(e, "abstractNumId"), "val") else { continue }
                var starts: [Int: Int] = [:]
                for o in Self.children(e) where o.localName == "lvlOverride" {
                    let index = Self.attr(o, "ilvl").flatMap(Int.init) ?? 0
                    if let start = Self.attr(Self.child(o, "startOverride"), "val").flatMap(Int.init) { starts[index] = start }
                }
                nums[id] = (abstract, starts)
            default:
                break
            }
        }
    }

    // MARK: Properties

    private func runProps(_ rPr: XMLElement?) -> RunProps {
        var p = RunProps()
        guard let rPr else { return p }
        for e in Self.children(rPr) {
            switch e.localName {
            case "b": p.bold = Self.isOn(e)
            case "i": p.italic = Self.isOn(e)
            case "strike", "dstrike": p.strike = Self.isOn(e)
            case "u": p.underline = (Self.attr(e, "val") ?? "single") != "none"
            case "vanish": p.hidden = Self.isOn(e)
            case "rFonts": p.font = fontName(e)
            case "sz": p.size = Self.attr(e, "val").flatMap(Double.init).map { $0 / 2 }
            case "color":
                if let v = Self.attr(e, "val"), v.count == 6, v.allSatisfy(\.isHexDigit) { p.color = v.uppercased() }
            default: break
            }
        }
        return p
    }

    private func fontName(_ e: XMLElement) -> String? {
        if let name = Self.attr(e, "ascii") ?? Self.attr(e, "hAnsi"), !name.isEmpty { return name }
        if let theme = Self.attr(e, "asciiTheme") ?? Self.attr(e, "hAnsiTheme") {
            return theme.hasPrefix("major") ? themeMajor : themeMinor
        }
        return Self.attr(e, "cs") ?? Self.attr(e, "eastAsia")
    }

    private func paraProps(_ pPr: XMLElement?) -> ParaProps {
        var p = ParaProps()
        guard let pPr else { return p }
        for e in Self.children(pPr) {
            switch e.localName {
            case "numPr":
                if let id = Self.attr(Self.child(e, "numId"), "val") { p.numId = id }
                if let level = Self.attr(Self.child(e, "ilvl"), "val").flatMap(Int.init) { p.level = level }
            case "outlineLvl":
                p.outline = Self.attr(e, "val").flatMap(Int.init)
            case "jc":
                switch Self.attr(e, "val") ?? "" {
                case "center": p.align = .center
                case "right", "end": p.align = .right
                case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": p.align = .justified
                default: p.align = .left
                }
            case "pBdr":
                if let bottom = Self.child(e, "bottom") {
                    let style = Self.attr(bottom, "val") ?? "none"
                    p.bottomBorder = style != "none" && style != "nil"
                }
            case "pageBreakBefore":
                p.pageBreakBefore = Self.isOn(e)
            default:
                break
            }
        }
        return p
    }

    /// A style and everything it's based on, root first.
    private func chain(_ id: String?) -> [Style] {
        var out: [Style] = []
        var seen: Set<String> = []
        var current = id
        while let c = current, !seen.contains(c), let style = styles[c] {
            out.append(style)
            seen.insert(c)
            current = style.basedOn
        }
        return out.reversed()
    }

    private static func names(_ chain: [Style]) -> [String] {
        chain.reversed().map { $0.name.lowercased() }
    }

    /// "list bullet 3" → 2.
    private static func listStyleDepth(_ name: String) -> Int? {
        guard name.hasPrefix("list "), let last = name.split(separator: " ").last, let n = Int(last), n > 1 else { return nil }
        return min(8, n - 1)
    }

    private static func headingLevel(_ names: [String]) -> Int? {
        for name in names {
            if name == "title" { return 1 }
            if name.hasPrefix("heading "), let level = Int(name.dropFirst(8)), (1...9).contains(level) { return level }
        }
        return nil
    }

    private static let quoteNames = ["quote", "block text"]
    private static let codeNames = ["code", "preformatted", "verbatim", "source"]
    private static let monoFonts = ["mono", "courier", "consolas", "menlo", "monaco", "code", "console", "andale",
                                    "inconsolata", "fixedsys", "typewriter"]

    private static func isMono(_ font: String?) -> Bool {
        guard let f = font?.lowercased() else { return false }
        return monoFonts.contains { f.contains($0) }
    }

    /// Near-white text only shows up on shading we don't carry over.
    private static func isPale(_ hex: String) -> Bool {
        guard let value = Int(hex, radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.9
    }

    // MARK: Lists

    private func numberingLevel(_ numId: String, _ level: Int) -> (abstract: String, format: String, start: Int)? {
        guard numId != "0", let num = nums[numId] else { return nil }
        var abstract = num.abstract
        var levels = abstracts[abstract] ?? [:]
        // A definition can point at a numbering style, which points at the real one.
        if levels.isEmpty, let link = abstractStyleLinks[abstract], let linkedNum = styles[link]?.para.numId,
           let target = nums[linkedNum] {
            abstract = target.abstract
            levels = abstracts[abstract] ?? [:]
        }
        guard let def = levels[level] ?? levels[0] else { return nil }
        return (abstract, def.format, num.starts[level] ?? def.start)
    }

    /// Word counts per numbering definition: lists that share one keep counting unless a start override restarts them.
    private func nextNumber(numId: String, abstract: String, level: Int, start: Int) -> Int {
        var levels = counters[abstract] ?? [:]
        if !startedNums.contains(numId) {
            startedNums.insert(numId)
            for (l, s) in nums[numId]?.starts ?? [:] {
                levels[l] = s - 1
                for deeper in levels.keys where deeper > l { levels[deeper] = nil }
            }
        }
        let number = (levels[level] ?? (start - 1)) + 1
        levels[level] = number
        for deeper in levels.keys where deeper > level { levels[deeper] = nil }
        counters[abstract] = levels
        return number
    }

    // MARK: Blocks

    private func readBlocks(_ container: XMLElement) -> [(Block, TextAlign?)] {
        var out: [(Block, TextAlign?)] = []
        for e in Self.children(container) {
            switch e.localName {
            case "p":
                out += paragraph(e)
            case "tbl":
                let rows = table(e)
                if !rows.isEmpty { out.append((.table(rows), nil)) }
            case "sdt":
                if let content = Self.child(e, "sdtContent") { out += readBlocks(content) }
            case "customXml", "ins", "moveTo":
                out += readBlocks(e)
            case "AlternateContent":
                if let choice = Self.choice(e) { out += readBlocks(choice) }
            default:
                break
            }
        }
        // Code paragraphs that follow each other are one block.
        var merged: [(Block, TextAlign?)] = []
        for item in out {
            if case let .code(text) = item.0, let last = merged.last, case let .code(previous) = last.0 {
                merged[merged.count - 1] = (.code(previous + "\n" + text), nil)
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    private func paragraph(_ p: XMLElement) -> [(Block, TextAlign?)] {
        let pPr = Self.child(p, "pPr")
        let styleChain = chain(Self.attr(Self.child(pPr, "pStyle"), "val") ?? defaultParagraphStyle)
        let styleNames = Self.names(styleChain)
        var props = ParaProps()
        for style in styleChain { props.apply(style.para) }
        props.apply(paraProps(pPr))
        var base = defaults
        for style in styleChain { base.apply(style.run) }

        var kind = Kind.paragraph
        if let level = Self.headingLevel(styleNames) ?? props.outline.flatMap({ $0 < 9 ? $0 + 1 : nil }) {
            kind = .heading(min(6, level))
        } else if let numId = props.numId, let def = numberingLevel(numId, props.level ?? 0), def.format != "none" {
            let level = min(8, props.level ?? 0)
            let number = nextNumber(numId: numId, abstract: def.abstract, level: level, start: def.start)
            // "List Bullet 2" and friends nest by style rather than by level.
            var depth = level
            if depth == 0, let styled = styleNames.lazy.compactMap(Self.listStyleDepth).first { depth = styled }
            kind = .list(ordered: def.format != "bullet", depth: depth, number: number)
        } else if styleNames.contains(where: { name in Self.quoteNames.contains { name.contains($0) } }) {
            kind = .quote
        } else if styleNames.contains(where: { name in Self.codeNames.contains { name.contains($0) } }) {
            kind = .code
        }

        var pieces: [Piece] = []
        walk(p, base: base, link: nil, into: &pieces)

        // A paragraph set entirely in a monospaced font is code.
        if case .paragraph = kind {
            let texts = pieces.compactMap { piece -> Inline? in
                if case let .text(run) = piece, !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return run }
                return nil
            }
            if !texts.isEmpty && texts.allSatisfy(\.code) { kind = .code }
        }

        var out: [(Block, TextAlign?)] = []
        if props.pageBreakBefore == true { out.append((.pageBreak, nil)) }
        let align = props.align
        var runs: [Inline] = []
        func flush() {
            defer { runs = [] }
            switch kind {
            case .code:
                let text = Inlines.plain(runs).trimmingCharacters(in: .newlines)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { out.append((.code(text), nil)) }
                return
            default:
                break
            }
            let normalized = Inlines.normalized(runs)
            guard !Inlines.plain(normalized).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            switch kind {
            case let .heading(level):
                // Headings are bold by style; keep the words, not the weight.
                out.append((.heading(level, Inlines.merged(normalized.map { var r = $0; r.bold = false; return r })), align))
            case let .list(ordered, depth, number):
                out.append((.listItem(ordered: ordered, depth: depth, number: number, normalized), align))
            case .quote:
                out.append((.quote(Inlines.merged(normalized.map { var r = $0; r.italic = false; return r })), align))
            case .paragraph, .code:
                out.append((.paragraph(normalized), align))
            }
        }
        for piece in pieces {
            switch piece {
            case let .text(run):
                runs.append(run)
            case let .image(data, ext, alt):
                flush()
                out.append((.image(data, ext: ext, alt: alt), align))
            case .pageBreak:
                flush()
                out.append((.pageBreak, nil))
            case let .blocks(blocks):
                flush()
                out += blocks
            }
        }
        flush()

        let hasContent = out.contains { if case .pageBreak = $0.0 { return false } else { return true } }
        if !hasContent && props.bottomBorder == true { out.append((.rule, nil)) }
        // A section break inside a paragraph starts a new page unless it's continuous.
        if let section = Self.child(pPr, "sectPr"), Self.attr(Self.child(section, "type"), "val") != "continuous" {
            out.append((.pageBreak, nil))
        }
        return out
    }

    // MARK: Runs

    private func walk(_ e: XMLElement, base: RunProps, link: String?, into pieces: inout [Piece]) {
        for child in Self.children(e) {
            switch child.localName {
            case "r":
                run(child, base: base, link: link, into: &pieces)
            case "hyperlink":
                var target = Self.relationshipAttr(child, "id").flatMap { rels[$0]?.target }
                if let anchor = Self.attr(child, "anchor"), !anchor.isEmpty {
                    target = (target ?? "") + "#" + anchor
                }
                walk(child, base: base, link: target ?? link, into: &pieces)
            case "fldSimple":
                let target = Self.hyperlink(fromInstruction: Self.attr(child, "instr") ?? "")
                walk(child, base: base, link: target ?? link, into: &pieces)
            case "ins", "smartTag", "customXml", "dir", "bdo", "moveTo":
                walk(child, base: base, link: link, into: &pieces)
            case "sdt":
                if let content = Self.child(child, "sdtContent") { walk(content, base: base, link: link, into: &pieces) }
            case "AlternateContent":
                if let choice = Self.choice(child) { walk(choice, base: base, link: link, into: &pieces) }
            case "oMath", "oMathPara":
                let text = Self.descendants(child).filter { $0.localName == "t" }.compactMap(\.stringValue).joined()
                if !text.isEmpty { pieces.append(.text(Inline(text: text, italic: true))) }
            default:
                break
            }
        }
    }

    private func run(_ r: XMLElement, base: RunProps, link: String?, into pieces: inout [Piece]) {
        let rPr = Self.child(r, "rPr")
        var props = base
        var codeStyle = false
        if let styleId = Self.attr(Self.child(rPr, "rStyle"), "val") {
            let styleChain = chain(styleId)
            for style in styleChain { props.apply(style.run) }
            codeStyle = Self.names(styleChain).contains { name in Self.codeNames.contains { name.contains($0) } }
        }
        props.apply(runProps(rPr))
        runContent(r, props: props, code: codeStyle, link: link, into: &pieces)
    }

    private func runContent(_ container: XMLElement, props: RunProps, code: Bool, link: String?, into pieces: inout [Piece]) {
        let visible = props.hidden != true
        func add(_ text: String) {
            guard visible, !fields.contains(where: { !$0.inResult }) else { return }
            let target = fields.last(where: { $0.inResult && $0.link != nil })?.link ?? link
            pieces.append(.text(makeInline(text, props: props, link: target, code: code)))
        }
        for e in Self.children(container) {
            switch e.localName {
            case "t":
                if Self.isMain(e) { add(e.stringValue ?? "") }
            case "tab", "ptab":
                add("\t")
            case "br":
                if Self.attr(e, "type") == "page" { if visible { pieces.append(.pageBreak) } } else { add("\n") }
            case "cr":
                add("\n")
            case "noBreakHyphen":
                add("-")
            case "sym":
                let font = (Self.attr(e, "font") ?? "").lowercased()
                if !font.contains("symbol") && !font.contains("wingdings") && !font.contains("webdings"),
                   let code = Self.attr(e, "char").flatMap({ UInt32($0, radix: 16) }), let scalar = Unicode.Scalar(code) {
                    add(String(Character(scalar)))
                }
            case "fldChar":
                switch Self.attr(e, "fldCharType") ?? "" {
                case "begin":
                    fields.append(Field())
                case "separate":
                    if !fields.isEmpty {
                        fields[fields.count - 1].inResult = true
                        fields[fields.count - 1].link = Self.hyperlink(fromInstruction: fields[fields.count - 1].instruction)
                    }
                case "end":
                    if !fields.isEmpty { fields.removeLast() }
                default:
                    break
                }
            case "instrText":
                if !fields.isEmpty, !fields[fields.count - 1].inResult { fields[fields.count - 1].instruction += e.stringValue ?? "" }
            case "drawing", "pict", "object":
                if visible { pictures(in: e, into: &pieces) }
            case "AlternateContent":
                if let choice = Self.choice(e) { runContent(choice, props: props, code: code, link: link, into: &pieces) }
            default:
                break
            }
        }
    }

    private func makeInline(_ text: String, props: RunProps, link: String?, code: Bool) -> Inline {
        var run = Inline(text: text)
        run.bold = props.bold ?? false
        run.italic = props.italic ?? false
        run.strike = props.strike ?? false
        run.link = link
        run.code = (code || Self.isMono(props.font)) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        run.font = props.font
        run.size = props.size
        if let color = props.color, !Self.isPale(color) { run.color = color }
        run.underline = (props.underline ?? false) && link == nil
        return run
    }

    /// Pictures and text boxes inside a drawing.
    private func pictures(in e: XMLElement, into pieces: inout [Piece]) {
        var alt = ""
        for d in Self.descendants(e, stopAt: ["txbxContent"]) {
            switch d.localName {
            case "docPr":
                alt = (Self.attr(d, "descr") ?? Self.attr(d, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case "shape":
                if let a = Self.attr(d, "alt"), !a.isEmpty { alt = a }
            case "blip":
                if let id = Self.relationshipAttr(d, "embed"), let image = image(id) { pieces.append(.image(image.data, image.ext, alt)) }
            case "imagedata":
                if let id = Self.relationshipAttr(d, "id"), let image = image(id) { pieces.append(.image(image.data, image.ext, alt)) }
            case "txbxContent":
                guard nesting < 4 else { continue }
                nesting += 1
                pieces.append(.blocks(readBlocks(d)))
                nesting -= 1
            default:
                break
            }
        }
    }

    private func image(_ id: String) -> (data: Data, ext: String)? {
        guard let rel = rels[id], !rel.external, let data = try? zip.read(rel.target),
              let image = DOCX.displayable(data, ext: (rel.target as NSString).pathExtension) else { return nil }
        return (image.data, image.ext)
    }

    // MARK: Tables

    private func table(_ tbl: XMLElement) -> [[[Inline]]] {
        guard nesting < 4 else { return [] }
        nesting += 1
        defer { nesting -= 1 }
        var rows: [[[Inline]]] = []
        for tr in Self.flattened(tbl, wanting: "tr") {
            var row: [[Inline]] = []
            let before = Self.attr(Self.child(Self.child(tr, "trPr"), "gridBefore"), "val").flatMap(Int.init) ?? 0
            row += Array(repeating: [], count: min(max(0, before), 50))
            for tc in Self.flattened(tr, wanting: "tc") {
                let tcPr = Self.child(tc, "tcPr")
                let span = Self.attr(Self.child(tcPr, "gridSpan"), "val").flatMap(Int.init) ?? 1
                let merge = Self.child(tcPr, "vMerge")
                let continuesAbove = merge != nil && (Self.attr(merge, "val") ?? "continue") != "restart"
                row.append(continuesAbove ? [] : cellRuns(tc))
                row += Array(repeating: [], count: min(max(0, span - 1), 50))
            }
            if !row.isEmpty { rows.append(row) }
        }
        // Drop rows and tables with nothing in them.
        rows = rows.filter { $0.contains { !Inlines.plain($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        // The first row is the header everywhere tables go; a header that's bold all over doesn't need the bold too.
        if rows.count > 1 {
            let words = rows[0].flatMap { $0 }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !words.isEmpty && words.allSatisfy(\.bold) {
                rows[0] = rows[0].map { cell in cell.map { var r = $0; r.bold = false; return r } }
            }
        }
        return rows
    }

    /// A cell's paragraphs as one run list, one line per paragraph.
    private func cellRuns(_ tc: XMLElement) -> [Inline] {
        var out: [Inline] = []
        for (block, _) in readBlocks(tc) {
            let runs: [Inline]
            switch block {
            case let .heading(_, r), let .paragraph(r), let .quote(r):
                runs = r
            case let .listItem(ordered, _, number, r):
                runs = [Inline(text: ordered ? "\(number). " : "• ")] + r
            case let .code(text):
                runs = [Inline(text: text, code: true)]
            case let .table(rows):
                runs = [Inline(text: rows.map { $0.map { Inlines.plain($0) }.joined(separator: " | ") }.joined(separator: "\n"))]
            case .image, .rule, .pageBreak:
                continue
            }
            if !out.isEmpty { out.append(Inline(text: "\n")) }
            out += runs
        }
        return out
    }

    // MARK: XML helpers

    private static func children(_ e: XMLElement?) -> [XMLElement] {
        e?.children?.compactMap { $0 as? XMLElement } ?? []
    }

    private static func child(_ e: XMLElement?, _ name: String) -> XMLElement? {
        children(e).first { $0.localName == name }
    }

    private static func attr(_ e: XMLElement?, _ name: String) -> String? {
        e?.attributes?.first { ($0.localName ?? $0.name) == name }?.stringValue
    }

    private static func relationshipAttr(_ e: XMLElement, _ name: String) -> String? {
        e.attributes?.first { $0.localName == name && relationshipNamespaces.contains($0.uri ?? "") }?.stringValue
            ?? attr(e, name)
    }

    private static func isMain(_ e: XMLElement) -> Bool {
        guard let uri = e.uri else { return true }
        return mainNamespaces.contains(uri)
    }

    private static func isOn(_ e: XMLElement) -> Bool {
        guard let value = attr(e, "val")?.lowercased() else { return true }
        return !["0", "false", "off", "none"].contains(value)
    }

    /// Markup-compatibility blocks: read the modern choice, skip the fallback copy.
    private static func choice(_ e: XMLElement) -> XMLElement? {
        child(e, "Choice") ?? child(e, "Fallback")
    }

    /// Every element below `e` in document order, skipping fallback copies and not going inside `stopAt` elements.
    private static func descendants(_ e: XMLElement, stopAt: Set<String> = []) -> [XMLElement] {
        var out: [XMLElement] = []
        func visit(_ node: XMLElement) {
            for c in children(node) {
                if c.localName == "Fallback" { continue }
                out.append(c)
                if !stopAt.contains(c.localName ?? "") { visit(c) }
            }
        }
        visit(e)
        return out
    }

    /// Rows or cells, including ones wrapped in content controls.
    private static func flattened(_ e: XMLElement, wanting name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in children(e) {
            switch c.localName {
            case name: out.append(c)
            case "sdt": if let content = child(c, "sdtContent") { out += flattened(content, wanting: name) }
            case "customXml": out += flattened(c, wanting: name)
            default: break
            }
        }
        return out
    }

    /// `HYPERLINK "https://…" \l "anchor"` → the link.
    static func hyperlink(fromInstruction instruction: String) -> String? {
        let trimmed = instruction.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("HYPERLINK") else { return nil }
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for ch in trimmed.dropFirst(9) {
            if ch == "\"" {
                if quoted { tokens.append(current); current = "" }
                quoted.toggle()
            } else if ch == " " && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        var url: String?
        var anchor: String?
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "\\l", i + 1 < tokens.count { anchor = tokens[i + 1]; i += 2; continue }
            if token == "\\m" || token == "\\n" { i += 1; continue }
            if token.hasPrefix("\\") { i += 2; continue }
            if url == nil { url = token }
            i += 1
        }
        if let url, !url.isEmpty { return anchor.map { url + "#" + $0 } ?? url }
        return anchor.map { "#" + $0 }
    }
}
