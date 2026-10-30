import Foundation

/// Markdown in and out: headings, paragraphs, lists, quotes, code, rules, tables, images, links and emphasis.
enum Markdown {
    // MARK: Reading

    static func read(_ source: String, title: String, baseURL: URL?) -> DocModel {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listIndents: [Int] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.enumerated().map { index, line -> String in
                var l = line
                let hardBreak = l.hasSuffix("  ") || l.hasSuffix("\\")
                l = l.trimmingCharacters(in: .whitespaces)
                if l.hasSuffix("\\") { l.removeLast() }
                return l + (index < paragraph.count - 1 ? (hardBreak ? "\n" : " ") : "")
            }.joined()
            paragraph = []
            if let image = standaloneImage(text, baseURL: baseURL) {
                blocks.append(image)
            } else {
                blocks.append(.paragraph(inlines(text)))
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            // Blank line.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Fenced code.
            if indent < 4, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                listIndents = []
                continue
            }

            // Setext heading underline.
            if !paragraph.isEmpty, indent < 4, trimmed.count >= 2,
               trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(trimmed.first == "=" ? 1 : 2, inlines(text)))
                i += 1
                continue
            }

            // ATX heading.
            if indent < 4, trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(hashes)
                if hashes <= 6, rest.isEmpty || rest.first == " " {
                    flushParagraph()
                    var text = rest.trimmingCharacters(in: .whitespaces)
                    while text.hasSuffix("#") { text.removeLast() }
                    blocks.append(.heading(hashes, inlines(text.trimmingCharacters(in: .whitespaces))))
                    listIndents = []
                    i += 1
                    continue
                }
            }

            // Thematic break.
            if indent < 4, isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                listIndents = []
                i += 1
                continue
            }

            // Block quote.
            if indent < 4, trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var body = String(t.dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quoted.append(body)
                    i += 1
                }
                // Paragraphs inside the quote become separate quote blocks.
                var current: [String] = []
                for q in quoted + [""] {
                    if q.trimmingCharacters(in: .whitespaces).isEmpty {
                        if !current.isEmpty { blocks.append(.quote(inlines(current.joined(separator: " ")))) }
                        current = []
                    } else {
                        current.append(q.trimmingCharacters(in: .whitespaces))
                    }
                }
                continue
            }

            // Table: a header row followed by a delimiter row.
            if trimmed.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushParagraph()
                var rows: [[[Inline]]] = [cells(trimmed).map(inlines)]
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(cells(t).map(inlines))
                    i += 1
                }
                let width = rows.map(\.count).max() ?? 0
                rows = rows.map { $0 + Array(repeating: [], count: max(0, width - $0.count)) }
                blocks.append(.table(rows))
                continue
            }

            // List item.
            if let item = listItem(line) {
                flushParagraph()
                while let last = listIndents.last, last > item.indent { listIndents.removeLast() }
                if listIndents.last != item.indent {
                    if let last = listIndents.last, item.indent < last + 2 {
                        listIndents[listIndents.count - 1] = item.indent
                    } else {
                        listIndents.append(item.indent)
                    }
                }
                var text = item.text
                // Lazy continuation lines belong to the item.
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let t = next.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || listItem(next) != nil || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || isRule(t) { break }
                    text += " " + t
                    j += 1
                }
                i = j
                if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
                else if text.lowercased().hasPrefix("[x] ") { text = "☑ " + text.dropFirst(4) }
                blocks.append(.listItem(ordered: item.number != nil, depth: max(0, listIndents.count - 1),
                                        number: item.number ?? 0, inlines(text)))
                continue
            }

            // Indented code (only outside lists and paragraphs).
            if indent >= 4, paragraph.isEmpty, listIndents.isEmpty {
                var code: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    let ind = l.prefix { $0 == " " }.count
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { code.append(""); i += 1; continue }
                    guard ind >= 4 || l.hasPrefix("\t") else { break }
                    code.append(l.hasPrefix("\t") ? String(l.dropFirst()) : String(l.dropFirst(4)))
                    i += 1
                }
                while code.last == "" { code.removeLast() }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // Raw HTML lines: keep the text, drop the tags.
            if indent < 4, trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
                let text = trimmed.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { paragraph.append(text) }
                i += 1
                continue
            }

            if paragraph.isEmpty { listIndents = [] }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        let docTitle = blocks.lazy.compactMap { block -> String? in
            if case let .heading(1, runs) = block { return Inlines.plain(runs) } else { return nil }
        }.first ?? title
        return DocModel(title: docTitle, blocks: blocks)
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|:- \t".contains($0) } && t.contains("|")
    }

    private static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var current = ""
        var escaped = false
        for ch in t {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "|" { out.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(ch) }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func listItem(_ line: String) -> (indent: Int, number: Int?, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            let text = after.trimmingCharacters(in: .whitespaces)
            // "* * *" is a rule, not a list.
            if isRule(String(rest)) { return nil }
            return (indent, nil, text)
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let marker = after.first, marker == "." || marker == ")" else { return nil }
        let body = after.dropFirst()
        guard body.first == " " || body.first == "\t" else { return nil }
        return (indent, Int(digits) ?? 1, body.trimmingCharacters(in: .whitespaces))
    }

    /// A paragraph that is only an image becomes an image block.
    private static func standaloneImage(_ text: String, baseURL: URL?) -> Block? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("!["), t.hasSuffix(")"),
              let closeAlt = t.range(of: "]("),
              t.distance(from: t.startIndex, to: closeAlt.lowerBound) >= 2 else { return nil }
        let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<closeAlt.lowerBound])
        var src = String(t[closeAlt.upperBound..<t.index(before: t.endIndex)])
        if let space = src.firstIndex(of: " ") { src = String(src[..<space]) }
        src = src.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !src.contains("]("), let (data, ext) = Resources.load(src, relativeTo: baseURL) else { return nil }
        return .image(data, ext: ext, alt: alt)
    }

    // MARK: Inline parsing

    static func inlines(_ text: String) -> [Inline] {
        var parser = InlineParser(Array(text))
        return Inlines.merged(parser.parse(style: Inline(text: "")))
    }

    private struct InlineParser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func parse(style: Inline, until closer: String? = nil) -> [Inline] {
            var out: [Inline] = []
            var buffer = ""
            let current = style

            func flush() {
                if !buffer.isEmpty {
                    var run = current
                    run.text = buffer
                    out.append(run)
                    buffer = ""
                }
            }

            while i < chars.count {
                if let closer, matches(closer, at: i) {
                    flush()
                    i += closer.count
                    return out
                }
                let c = chars[i]
                // Escapes.
                if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>".contains(chars[i + 1]) {
                    buffer.append(chars[i + 1])
                    i += 2
                    continue
                }
                // Code span.
                if c == "`" {
                    let ticks = run(of: "`", at: i)
                    if let end = find(String(repeating: "`", count: ticks), from: i + ticks) {
                        flush()
                        var code = current
                        code.code = true
                        code.text = String(chars[(i + ticks)..<end]).trimmingCharacters(in: .whitespaces)
                        out.append(code)
                        i = end + ticks
                        continue
                    }
                }
                // Images inline: keep the alt text.
                if c == "!", i + 1 < chars.count, chars[i + 1] == "[", let link = linkAt(i + 1) {
                    buffer += link.label
                    i = link.end
                    continue
                }
                // Links.
                if c == "[", let link = linkAt(i) {
                    flush()
                    var sub = InlineParser(Array(link.label))
                    var linked = current
                    linked.link = link.url
                    out += sub.parse(style: linked)
                    i = link.end
                    continue
                }
                // Autolinks.
                if c == "<", let close = find(">", from: i + 1) {
                    let inner = String(chars[(i + 1)..<close])
                    if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                        flush()
                        var linked = current
                        linked.link = inner
                        linked.text = inner.replacingOccurrences(of: "mailto:", with: "")
                        out.append(linked)
                        i = close + 1
                        continue
                    }
                }
                // Strikethrough.
                if c == "~", matches("~~", at: i) {
                    if current.strike {
                        if closer == "~~" { flush(); i += 2; return out }
                    } else if find("~~", from: i + 2) != nil {
                        flush()
                        i += 2
                        var styled = current
                        styled.strike = true
                        out += parse(style: styled, until: "~~")
                        continue
                    }
                }
                // Bold and italic.
                if c == "*" || c == "_" {
                    let count = run(of: c, at: i)
                    let before: Character? = i > 0 ? chars[i - 1] : nil
                    let after: Character? = i + count < chars.count ? chars[i + count] : nil
                    let canOpen = after != nil && !after!.isWhitespace && (c == "*" || before == nil || !(before!.isLetter || before!.isNumber))
                    if canOpen, count >= 2, !current.bold, find(String(repeating: c, count: 2), from: i + 2) != nil {
                        flush()
                        i += 2
                        var styled = current
                        styled.bold = true
                        out += parse(style: styled, until: String(repeating: c, count: 2))
                        continue
                    }
                    if canOpen, count == 1 || (count >= 2 && current.bold), !current.italic,
                       let end = find(String(c), from: i + 1), end > i + 1 {
                        _ = end
                        flush()
                        i += 1
                        var styled = current
                        styled.italic = true
                        out += parse(style: styled, until: String(c))
                        continue
                    }
                }
                buffer.append(c)
                i += 1
            }
            flush()
            return out
        }

        func matches(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s)
            guard index + pattern.count <= chars.count else { return false }
            for (k, p) in pattern.enumerated() where chars[index + k] != p { return false }
            // A closing single "*" shouldn't eat half of a "**".
            if pattern.count == 1, pattern[0] == "*" || pattern[0] == "_" {
                if index + 1 < chars.count, chars[index + 1] == pattern[0] { return false }
                if index > 0, chars[index - 1].isWhitespace { return false }
            }
            return true
        }

        func run(of c: Character, at index: Int) -> Int {
            var n = 0
            while index + n < chars.count, chars[index + n] == c { n += 1 }
            return n
        }

        func find(_ s: String, from start: Int) -> Int? {
            var k = start
            while k < chars.count {
                if matches(s, at: k) { return k }
                k += 1
            }
            return nil
        }

        /// "[label](url)" starting at `start`.
        func linkAt(_ start: Int) -> (label: String, url: String, end: Int)? {
            var depth = 0
            var k = start
            while k < chars.count {
                if chars[k] == "[" { depth += 1 }
                if chars[k] == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                k += 1
            }
            guard k + 1 < chars.count, chars[k + 1] == "(" else { return nil }
            guard let close = find(")", from: k + 2) else { return nil }
            let label = String(chars[(start + 1)..<k])
            var url = String(chars[(k + 2)..<close]).trimmingCharacters(in: .whitespaces)
            if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }
            url = url.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return (label, url, close + 1)
        }
    }

    // MARK: Writing

    /// Markdown text, plus the images it refers to (saved next to it in "<name> images").
    static func write(_ doc: DocModel, imageFolder: String) -> (String, [(name: String, data: Data)]) {
        var parts: [(text: String, isList: Bool)] = []
        var files: [(String, Data)] = []
        var lastNumber: [Int: Int] = [:]
        // Where a top-level list switches between bullets and numbers, a blank line keeps them two lists.
        var topOrdered: Bool?

        for block in doc.blocks {
            var isList = false
            var text = ""
            switch block {
            case let .heading(level, runs):
                text = String(repeating: "#", count: min(6, max(1, level))) + " " + inline(runs)
            case let .paragraph(runs):
                text = inline(runs)
            case let .listItem(ordered, depth, number, runs):
                isList = true
                if depth == 0 {
                    if let previous = topOrdered, previous != ordered { parts.append(("", false)) }
                    topOrdered = ordered
                }
                let indent = String(repeating: "    ", count: depth)
                let n = ordered ? (number > 0 ? number : (lastNumber[depth] ?? 0) + 1) : 0
                lastNumber[depth] = n
                text = indent + (ordered ? "\(n). " : "- ") + inline(runs)
            case let .quote(runs):
                text = inline(runs).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }.joined(separator: "\n")
            case let .code(code):
                let fence = code.contains("```") ? "~~~" : "```"
                text = fence + "\n" + code + "\n" + fence
            case .rule:
                text = "---"
            case let .image(data, ext, alt):
                let name = "image-\(files.count + 1).\(ext)"
                files.append((name, data))
                let path = (imageFolder + "/" + name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                text = "![\(alt.replacingOccurrences(of: "]", with: ""))](\(path))"
            case let .table(rows):
                guard let header = rows.first else { continue }
                let width = rows.map(\.count).max() ?? header.count
                func row(_ cells: [[Inline]]) -> String {
                    let padded = cells + Array(repeating: [], count: max(0, width - cells.count))
                    return "| " + padded.map { inline($0).replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
                }
                var t = [row(header), "|" + Array(repeating: " --- |", count: width).joined()]
                t += rows.dropFirst().map(row)
                text = t.joined(separator: "\n")
            case .pageBreak:
                continue
            }
            if !isList { lastNumber = [:]; topOrdered = nil }
            parts.append((text, isList))
        }
        var out = ""
        for (i, part) in parts.enumerated() {
            if part.text.isEmpty { continue }
            if !out.isEmpty { out += part.isList && parts[i - 1].isList ? "\n" : "\n\n" }
            out += part.text
        }
        return (out + "\n", files)
    }

    /// Inline runs as Markdown.
    static func inline(_ runs: [Inline]) -> String {
        var out = ""
        for run in Inlines.merged(runs) {
            if run.code {
                let ticks = run.text.contains("`") ? "``" : "`"
                var t = ticks + run.text + ticks
                if let link = run.link { t = "[\(t)](\(link))" }
                out += t
                continue
            }
            let lines = run.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var styledLines: [String] = []
            for line in lines {
                let core = line.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty else { styledLines.append(line); continue }
                let lead = String(line.prefix { $0 == " " })
                let trail = String(line.reversed().prefix { $0 == " " })
                var t = escape(core)
                if run.strike { t = "~~\(t)~~" }
                if run.italic { t = "*\(t)*" }
                if run.bold { t = "**\(t)**" }
                if let link = run.link { t = "[\(t)](\(link.replacingOccurrences(of: " ", with: "%20")))" }
                styledLines.append(lead + t + trail)
            }
            out += styledLines.joined(separator: "  \n")
        }
        return out
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            switch c {
            case "\\", "`", "*", "[", "]":
                out += "\\" + String(c)
            case "_":
                let before = i > 0 ? chars[i - 1] : " "
                let after = i + 1 < chars.count ? chars[i + 1] : " "
                out += (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber) ? "_" : "\\_"
            case "#" where i == 0, "<" where i == 0:
                out += "\\" + String(c)
            default:
                out.append(c)
            }
        }
        // A line that starts like a list marker would turn into a list.
        if let first = out.first, "-+".contains(first), out.dropFirst().first == " " { out = "\\" + out }
        if let match = out.range(of: #"^\d+\. "#, options: .regularExpression) {
            out.replaceSubrange(match, with: out[match].replacingOccurrences(of: ". ", with: "\\. "))
        }
        return out
    }
}

/// Loads images a document refers to: local files, file URLs and data URIs.
enum Resources {
    static func load(_ src: String, relativeTo base: URL?) -> (Data, String)? {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ","), src[..<comma].contains("base64") else { return nil }
            let mime = src.dropFirst(5).prefix { $0 != ";" && $0 != "," }
            guard let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters) else { return nil }
            return (data, ext(forMime: String(mime)))
        }
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return nil }
        let path = src.removingPercentEncoding ?? src
        let url: URL
        if path.hasPrefix("file://"), let u = URL(string: src) { url = u }
        else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if let base { url = base.appendingPathComponent(path) }
        else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let e = url.pathExtension.lowercased()
        return (data, e.isEmpty ? "png" : (e == "jpeg" ? "jpg" : e))
    }

    static func ext(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/svg+xml": "svg"
        case "image/webp": "webp"
        default: "png"
        }
    }

    static func mime(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: "image/png"
        }
    }
}
