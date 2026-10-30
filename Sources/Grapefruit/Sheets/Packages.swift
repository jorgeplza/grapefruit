import Foundation

// MARK: - XLSX

enum XLSX {
    static func read(_ url: URL) throws -> [Sheet] {
        let zip = try ZipReader(url: url)
        let workbook = try XMLDocument(data: zip.read("xl/workbook.xml"))
        let date1904 = (try workbook.nodes(forXPath: "//*[local-name()='workbookPr']/@date1904").first?.stringValue)
            .map { $0 == "1" || $0 == "true" } ?? false

        var targets: [String: String] = [:]
        if let rels = try? XMLDocument(data: zip.read("xl/_rels/workbook.xml.rels")) {
            for node in try rels.nodes(forXPath: "//*[local-name()='Relationship']") {
                guard let e = node as? XMLElement, let id = e.attribute(forName: "Id")?.stringValue,
                      var target = e.attribute(forName: "Target")?.stringValue else { continue }
                if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
                targets[id] = target
            }
        }

        let shared = (try? zip.read("xl/sharedStrings.xml")).map(SharedStrings.parse) ?? []
        let dateStyles = (try? zip.read("xl/styles.xml")).map(dateStyleIndexes) ?? []

        var sheets: [Sheet] = []
        for (index, node) in try workbook.nodes(forXPath: "//*[local-name()='sheets']/*[local-name()='sheet']").enumerated() {
            guard let e = node as? XMLElement else { continue }
            let name = e.attribute(forName: "name")?.stringValue ?? "Sheet\(index + 1)"
            let rid = e.attributes?.first { $0.localName == "id" }?.stringValue ?? ""
            let path = targets[rid] ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let data = try? zip.read(path) else { continue }
            let parser = SheetParser(shared: shared, dateStyles: dateStyles, date1904: date1904)
            sheets.append(Sheet(name: name, rows: parser.parse(data)).trimmed)
        }
        guard !sheets.isEmpty else { throw JobError.failed("This workbook has no sheets.") }
        return sheets
    }

    /// Style indexes whose number format is a date or time.
    private static func dateStyleIndexes(_ data: Data) -> Set<Int> {
        guard let doc = try? XMLDocument(data: data) else { return [] }
        var custom: [Int: String] = [:]
        for node in (try? doc.nodes(forXPath: "//*[local-name()='numFmts']/*[local-name()='numFmt']")) ?? [] {
            guard let e = node as? XMLElement, let id = Int(e.attribute(forName: "numFmtId")?.stringValue ?? ""),
                  let code = e.attribute(forName: "formatCode")?.stringValue else { continue }
            custom[id] = code
        }
        var result: Set<Int> = []
        let xfs = (try? doc.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']")) ?? []
        for (i, node) in xfs.enumerated() {
            guard let e = node as? XMLElement, let id = Int(e.attribute(forName: "numFmtId")?.stringValue ?? "") else { continue }
            if (14...22).contains(id) || (45...47).contains(id) || (27...36).contains(id) || (50...58).contains(id) {
                result.insert(i)
            } else if let code = custom[id] {
                // Strip quoted text and colours, then look for date letters.
                let bare = code.replacingOccurrences(of: #""[^"]*"|\[[^\]]*\]|\\."#, with: "", options: .regularExpression).lowercased()
                if bare.contains("y") || bare.contains("d") || (bare.contains("m") && !bare.contains("0")) || bare.contains("h") {
                    result.insert(i)
                }
            }
        }
        return result
    }

    static func date(fromSerial serial: Double, date1904: Bool) -> Date {
        // Day zero is 1899-12-30 in the 1900 system (allowing for Excel's 1900 leap-year bug), 1904-01-01 in the other.
        Date(timeIntervalSince1970: (date1904 ? -2_082_844_800 : -2_209_161_600) + serial * 86_400)
    }

    private enum SharedStrings {
        static func parse(_ data: Data) -> [String] {
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.strings
        }

        final class Delegate: NSObject, XMLParserDelegate {
            var strings: [String] = []
            private var current = ""
            private var inText = false
            private var inPhonetic = false

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                switch local(name) {
                case "si": current = ""
                case "t": inText = !inPhonetic
                case "rPh": inPhonetic = true
                default: break
                }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch local(name) {
                case "si": strings.append(current)
                case "t": inText = false
                case "rPh": inPhonetic = false
                default: break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inText { current += string }
            }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        let dateStyles: Set<Int>
        let date1904: Bool
        private var rows: [Int: [Int: CellValue]] = [:]
        private var rowIndex = 0
        private var column = 0
        private var type = ""
        private var style = 0
        private var value = ""
        private var collecting = false
        private var inInline = false

        init(shared: [String], dateStyles: Set<Int>, date1904: Bool) {
            self.shared = shared
            self.dateStyles = dateStyles
            self.date1904 = date1904
        }

        func parse(_ data: Data) -> [[CellValue]] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            guard let maxRow = rows.keys.max() else { return [] }
            return (0...maxRow).map { r in
                guard let cells = rows[r], let maxCol = cells.keys.max() else { return [] }
                return (0...maxCol).map { cells[$0] ?? .empty }
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "row":
                if let r = attributes["r"], let n = Int(r) { rowIndex = n - 1 } else { rowIndex = (rows.keys.max() ?? -1) + 1 }
                column = 0
            case "c":
                if let ref = attributes["r"] { column = XLSX.columnIndex(ref) }
                type = attributes["t"] ?? "n"
                style = Int(attributes["s"] ?? "") ?? 0
                value = ""
            case "v":
                collecting = true
            case "is":
                inInline = true
            case "t":
                if inInline { collecting = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "v": collecting = false
            case "t": if inInline { collecting = false }
            case "is": inInline = false
            case "c":
                rows[rowIndex, default: [:]][column] = cellValue()
                column += 1
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { value += string }
        }

        private func cellValue() -> CellValue {
            switch type {
            case "s":
                guard let i = Int(value), i >= 0, i < shared.count else { return .empty }
                return shared[i].isEmpty ? .empty : .text(shared[i])
            case "inlineStr", "str":
                return value.isEmpty ? .empty : .text(value)
            case "b":
                return .bool(value == "1" || value.lowercased() == "true")
            case "e":
                return .text(value)
            case "d":
                return ISO8601DateFormatter().date(from: value).map(CellValue.date) ?? .text(value)
            default:
                guard let n = Double(value) else { return value.isEmpty ? .empty : .text(value) }
                if dateStyles.contains(style) { return .date(XLSX.date(fromSerial: n, date1904: date1904)) }
                return .number(n)
            }
        }
    }

    /// "AB12" → 27.
    static func columnIndex(_ reference: String) -> Int {
        var n = 0
        for ch in reference.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(0, n - 1)
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    static func serial(from date: Date) -> Double {
        (date.timeIntervalSince1970 + 2_209_161_600) / 86_400
    }

    // MARK: Writing

    static func write(_ sheets: [Sheet], to url: URL) throws {
        let zip = ZipWriter()
        let names = uniqueNames(sheets.map(\.name))
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        \(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined(separator: "\n"))
        </Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """)
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        \(names.enumerated().map { "<sheet name=\"\($1.xmlEscaped)\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined(separator: "\n"))
        </sheets>
        </workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined(separator: "\n"))
        <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """)
        // Style 0: default. 1: date. 2: date and time.
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm:ss"/></numFmts>
        <fonts count="1"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="3">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """)
        for (i, sheet) in sheets.enumerated() {
            zip.add("xl/worksheets/sheet\(i + 1).xml", worksheet(sheet.trimmed))
        }
        try zip.write(to: url)
    }

    private static func worksheet(_ sheet: Sheet) -> String {
        var widths = Array(repeating: 8, count: max(1, sheet.width))
        var xml = ""
        xml.reserveCapacity(sheet.rows.count * 64)
        for (r, row) in sheet.rows.enumerated() {
            guard !row.isEmpty else { continue }
            xml += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() {
                let ref = columnName(c) + String(r + 1)
                widths[c] = min(60, max(widths[c], cell.display.count + 2))
                switch cell {
                case .empty: continue
                case .text(let s):
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(s.xmlEscaped)</t></is></c>"
                case .number(let n):
                    xml += "<c r=\"\(ref)\"><v>\(n.isFinite ? CellValue.format(n) : "0")</v></c>"
                case .bool(let b):
                    xml += "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .date(let d):
                    let serial = serial(from: d)
                    let style = serial == serial.rounded() ? 1 : 2
                    xml += "<c r=\"\(ref)\" s=\"\(style)\"><v>\(serial)</v></c>"
                }
            }
            xml += "</row>"
        }
        let cols = widths.enumerated().map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\($1)\" customWidth=\"1\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>\(cols)</cols><sheetData>\(xml)</sheetData></worksheet>
        """
    }

    /// Sheet names: 31 characters, no []:*?/\, no repeats.
    static func uniqueNames(_ names: [String]) -> [String] {
        var used: Set<String> = []
        return names.enumerated().map { i, raw in
            var base = String(raw.filter { !"[]:*?/\\".contains($0) }.prefix(31)).trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "Sheet\(i + 1)" }
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                let suffix = " \(n)"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }
}

private func local(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

// MARK: - ODS

enum ODS {
    static func read(_ url: URL) throws -> [Sheet] {
        let zip = try ZipReader(url: url)
        let parser = ContentParser()
        let xml = XMLParser(data: try zip.read("content.xml"))
        xml.delegate = parser
        xml.parse()
        guard !parser.sheets.isEmpty else { throw JobError.failed("This spreadsheet has no tables.") }
        return parser.sheets.map(\.trimmed)
    }

    private final class ContentParser: NSObject, XMLParserDelegate {
        var sheets: [Sheet] = []
        private var rows: [[CellValue]] = []
        private var row: [CellValue] = []
        private var pendingEmptyRows = 0
        private var pendingEmptyCells = 0
        private var rowRepeat = 1
        private var cellRepeat = 1
        private var cellValue: CellValue = .empty
        private var cellText = ""
        private var paragraphs = 0
        private var inCell = false
        private var sheetName = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "table:table":
                sheetName = attributes["table:name"] ?? "Sheet\(sheets.count + 1)"
                rows = []
                pendingEmptyRows = 0
            case "table:table-row":
                row = []
                pendingEmptyCells = 0
                rowRepeat = min(Int(attributes["table:number-rows-repeated"] ?? "") ?? 1, 100_000)
            case "table:table-cell", "table:covered-table-cell":
                inCell = true
                cellText = ""
                paragraphs = 0
                cellRepeat = min(Int(attributes["table:number-columns-repeated"] ?? "") ?? 1, 16_384)
                switch attributes["office:value-type"] ?? "" {
                case "float", "percentage", "currency":
                    cellValue = Double(attributes["office:value"] ?? "").map(CellValue.number) ?? .empty
                case "boolean":
                    cellValue = .bool(attributes["office:boolean-value"] == "true")
                case "date":
                    let raw = attributes["office:date-value"] ?? ""
                    cellValue = ODS.parseDate(raw).map(CellValue.date) ?? .text(raw)
                case "time":
                    cellValue = .text(attributes["office:time-value"] ?? "")
                default:
                    cellValue = .empty
                }
            case "text:p":
                if inCell, paragraphs > 0 { cellText += "\n" }
                paragraphs += 1
            case "text:s":
                if inCell { cellText += String(repeating: " ", count: Int(attributes["text:c"] ?? "") ?? 1) }
            case "text:tab":
                if inCell { cellText += "\t" }
            case "text:line-break":
                if inCell { cellText += "\n" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "table:table-cell", "table:covered-table-cell":
                inCell = false
                var value = cellValue
                if value == .empty, !cellText.isEmpty { value = .text(cellText) }
                if value == .empty {
                    pendingEmptyCells += cellRepeat
                } else {
                    row += Array(repeating: .empty, count: pendingEmptyCells)
                    pendingEmptyCells = 0
                    row += Array(repeating: value, count: cellRepeat)
                }
            case "table:table-row":
                if row.isEmpty {
                    pendingEmptyRows += rowRepeat
                } else {
                    rows += Array(repeating: [], count: pendingEmptyRows)
                    pendingEmptyRows = 0
                    rows += Array(repeating: row, count: min(rowRepeat, 1_000))
                }
            case "table:table":
                sheets.append(Sheet(name: sheetName, rows: rows))
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCell { cellText += string }
        }
    }

    static func parseDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    static func write(_ sheets: [Sheet], to url: URL) throws {
        let zip = ZipWriter()
        zip.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", compress: false)
        zip.add("META-INF/manifest.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
         <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """)
        zip.add("styles.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.2"/>
        """)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var tables = ""
        for (name, sheet) in Swift.zip(XLSX.uniqueNames(sheets.map(\.name)), sheets.map(\.trimmed)) {
            tables += "<table:table table:name=\"\(name.xmlEscaped)\">"
            tables += "<table:table-column table:number-columns-repeated=\"\(max(1, sheet.width))\"/>"
            for row in sheet.rows {
                tables += "<table:table-row>"
                if row.isEmpty { tables += "<table:table-cell/>" }
                for cell in row {
                    switch cell {
                    case .empty:
                        tables += "<table:table-cell/>"
                    case .text(let s):
                        let paragraphs = s.components(separatedBy: "\n").map { "<text:p>\($0.xmlEscaped)</text:p>" }.joined()
                        tables += "<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    case .number(let n):
                        tables += "<table:table-cell office:value-type=\"float\" office:value=\"\(CellValue.format(n))\"><text:p>\(CellValue.format(n))</text:p></table:table-cell>"
                    case .bool(let b):
                        tables += "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"\(b)\"><text:p>\(b ? "TRUE" : "FALSE")</text:p></table:table-cell>"
                    case .date(let d):
                        tables += "<table:table-cell office:value-type=\"date\" office:date-value=\"\(f.string(from: d))\"><text:p>\(CellValue.dateText(d))</text:p></table:table-cell>"
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }
        zip.add("content.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """)
        try zip.write(to: url)
    }
}

// MARK: - PPTX (slides made of page images)

enum PPTX {
    static func write(slides: [Data], aspect: CGSize, to url: URL) throws {
        guard !slides.isEmpty else { throw JobError.failed("Nothing to put on slides.") }
        let cx = 12_192_000
        let cy = max(914_400, min(51_206_400, Int(Double(cx) * Double(aspect.height) / Double(max(1, aspect.width)))))
        let zip = ZipWriter()
        let n = slides.count

        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \((1...n).map { "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined(separator: "\n"))
        </Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """)
        zip.add("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\((1...n).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined())</p:sldIdLst>
        <p:sldSz cx="\(cx)" cy="\(cy)"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """)
        zip.add("ppt/_rels/presentation.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        \((1...n).map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0).xml\"/>" }.joined(separator: "\n"))
        <Relationship Id="rId\(n + 2)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        </Relationships>
        """)
        let emptyTree = """
        <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
        """
        zip.add("ppt/slideMasters/slideMaster1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        \(emptyTree)
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """)
        zip.add("ppt/slideLayouts/slideLayout1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
        \(emptyTree.replacingOccurrences(of: "<p:cSld>", with: "<p:cSld name=\"Blank\">"))
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """)
        zip.add("ppt/theme/theme1.xml", theme)

        for (i, png) in slides.enumerated() {
            let size = pngSize(png) ?? aspect
            // Fit the page inside the slide.
            let scale = min(Double(cx) / Double(size.width), Double(cy) / Double(size.height))
            let w = Int(Double(size.width) * scale), h = Int(Double(size.height) * scale)
            let x = (cx - w) / 2, y = (cy - h) / 2
            zip.add("ppt/media/image\(i + 1).png", png, compress: false)
            zip.add("ppt/slides/slide\(i + 1).xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:cSld><p:spTree>
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
            <p:pic>
            <p:nvPicPr><p:cNvPr id="2" name="Page \(i + 1)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
            <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
            </p:pic>
            </p:spTree></p:cSld>
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sld>
            """)
            zip.add("ppt/slides/_rels/slide\(i + 1).xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(i + 1).png"/>
            </Relationships>
            """)
        }
        try zip.write(to: url)
    }

    private static func pngSize(_ data: Data) -> CGSize? {
        guard data.count > 24 else { return nil }
        let w = Int(data[data.startIndex + 16]) << 24 | Int(data[data.startIndex + 17]) << 16 | Int(data[data.startIndex + 18]) << 8 | Int(data[data.startIndex + 19])
        let h = Int(data[data.startIndex + 20]) << 24 | Int(data[data.startIndex + 21]) << 16 | Int(data[data.startIndex + 22]) << 8 | Int(data[data.startIndex + 23])
        return w > 0 && h > 0 ? CGSize(width: w, height: h) : nil
    }

    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Grapefruit">
    <a:themeElements>
    <a:clrScheme name="Grapefruit">
    <a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
    <a:dk2><a:srgbClr val="1F1F1F"/></a:dk2><a:lt2><a:srgbClr val="F4F4F2"/></a:lt2>
    <a:accent1><a:srgbClr val="F35B28"/></a:accent1><a:accent2><a:srgbClr val="2F6FDB"/></a:accent2>
    <a:accent3><a:srgbClr val="2E9E5B"/></a:accent3><a:accent4><a:srgbClr val="E6B325"/></a:accent4>
    <a:accent5><a:srgbClr val="8A5CD6"/></a:accent5><a:accent6><a:srgbClr val="6B6B6B"/></a:accent6>
    <a:hlink><a:srgbClr val="2F6FDB"/></a:hlink><a:folHlink><a:srgbClr val="8A5CD6"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="Grapefruit">
    <a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
    <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
    </a:fontScheme>
    <a:fmtScheme name="Grapefruit">
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
    </a:fmtScheme>
    </a:themeElements>
    </a:theme>
    """
}
