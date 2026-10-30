import AppKit

enum CellValue: Equatable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(Date)

    var display: String {
        switch self {
        case .empty: return ""
        case .text(let s): return s
        case .number(let n): return CellValue.format(n)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .date(let d): return CellValue.dateText(d)
        }
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.10g", n)
        if s.contains("e") { s = String(n) }
        return s
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        f.dateFormat = (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// Text from a CSV or PDF cell: plain numbers become numbers, the rest stays text.
    static func guess(_ raw: String) -> CellValue {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        // Leading zeros (ZIP codes, IDs) stay text.
        if t.count > 1, t.hasPrefix("0"), !t.hasPrefix("0.") { return .text(raw) }
        let cleaned = t.replacingOccurrences(of: ",", with: "")
        if cleaned.range(of: #"^-?\d+(\.\d+)?([eE][-+]?\d+)?$"#, options: .regularExpression) != nil,
           let n = Double(cleaned), cleaned.filter(\.isNumber).count <= 15 {
            // Commas only count as thousands separators in groups of three.
            if t.contains(","), t.range(of: #"^-?\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) == nil { return .text(raw) }
            return .number(n)
        }
        return .text(raw)
    }
}

struct Sheet {
    var name: String
    var rows: [[CellValue]]

    var width: Int { rows.map(\.count).max() ?? 0 }

    /// Drops trailing empty cells and rows.
    var trimmed: Sheet {
        var r = rows.map { row -> [CellValue] in
            var row = row
            while row.last == .empty { row.removeLast() }
            return row
        }
        while r.last?.isEmpty == true { r.removeLast() }
        return Sheet(name: name, rows: r)
    }
}

// MARK: - CSV and TSV

enum DelimitedText {
    static func read(_ url: URL, separator explicit: Character?) throws -> Sheet {
        let data = try Data(contentsOf: url)
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let separator = explicit ?? detectSeparator(text)
        var rows: [[CellValue]] = []
        var row: [CellValue] = []
        var field = ""
        var quoted = false
        var wasQuoted = false
        var chars = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(wasQuoted ? (field.isEmpty ? .empty : .text(field)) : CellValue.guess(field))
            field = ""
            wasQuoted = false
        }

        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") }
                        else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty:
                quoted = true
                wasQuoted = true
            case separator:
                endField()
            case "\n", "\r\n", "\r":
                endField()
                rows.append(row)
                row = []
            default:
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty || wasQuoted {
            endField()
            rows.append(row)
        }
        return Sheet(name: Output.stem(url), rows: rows).trimmed
    }

    private static func detectSeparator(_ text: String) -> Character {
        let sample = text.prefix(4000)
        let counts: [(Character, Int)] = [",", ";", "\t", "|"].map { c in (c, sample.filter { $0 == c }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    static func write(_ sheet: Sheet, separator: Character) -> String {
        sheet.trimmed.rows.map { row in
            row.map { cell -> String in
                let s = cell.display
                if separator == "\t" {
                    return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                }
                if s.contains(separator) || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return s
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Tables as PDF

enum SheetPDF {
    /// Each sheet as a ruled table, wide sheets in landscape.
    static func write(_ sheets: [Sheet], to url: URL, ctx: JobContext) throws {
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 8.5)
        let bold = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        let widest = sheets.map(\.width).max() ?? 1
        let landscape = widest > 6
        var page = RichText.pageSize
        if landscape { page = CGSize(width: page.height, height: page.width) }

        for (s, sheet) in sheets.enumerated() {
            let sheet = sheet.trimmed
            guard !sheet.rows.isEmpty else { continue }
            if sheets.count > 1 {
                let p = NSMutableParagraphStyle()
                p.paragraphSpacing = 8
                p.paragraphSpacingBefore = s == 0 ? 0 : 14
                text.append(NSAttributedString(string: sheet.name + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .paragraphStyle: p,
                ]))
            }
            let table = NSTextTable()
            table.numberOfColumns = max(1, sheet.width)
            table.collapsesBorders = true
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            for (r, row) in sheet.rows.enumerated() {
                for c in 0..<table.numberOfColumns {
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(NSColor(white: 0.8, alpha: 1))
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    if r == 0 { block.backgroundColor = NSColor(white: 0.955, alpha: 1) }
                    let p = NSMutableParagraphStyle()
                    p.textBlocks = [block]
                    let value = c < row.count ? row[c] : .empty
                    if case .number = value { p.alignment = .right }
                    text.append(NSAttributedString(string: (value.display.isEmpty ? " " : value.display) + "\n", attributes: [
                        .font: r == 0 ? bold : font, .paragraphStyle: p,
                    ]))
                }
                if r % 200 == 0 { try ctx.checkCancelled() }
            }
        }
        try RichText.writePDF(text, to: url, pageSize: page, margin: 36, ctx: ctx)
    }
}
