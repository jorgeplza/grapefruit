import Foundation

/// HTML and XHTML in and out.
enum HTMLDoc {
    /// `resolve` turns an <img src> into image bytes and an extension.
    static func read(_ data: Data, title: String, resolve: @escaping (String) -> (Data, String)?) -> DocModel {
        let document = (try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]))
            ?? (try? XMLDocument(data: data, options: [.documentTidyXML]))
        guard let root = document?.rootElement() else {
            return PlainText.read(String(decoding: data, as: UTF8.self), title: title)
        }
        var walker = Walker(resolve: resolve)
        let body = first(named: "body", in: root) ?? root
        walker.blocks(in: body)
        walker.flush()
        var docTitle = title
        if let t = first(named: "title", in: root)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            docTitle = t
        }
        return DocModel(title: docTitle, blocks: walker.out)
    }

    static func first(named name: String, in node: XMLNode) -> XMLElement? {
        if let e = node as? XMLElement, e.localName?.lowercased() == name { return e }
        for child in node.children ?? [] {
            if let found = first(named: name, in: child) { return found }
        }
        return nil
    }

    private struct Walker {
        let resolve: (String) -> (Data, String)?
        var out: [Block] = []
        var pending: [Inline] = []

        init(resolve: @escaping (String) -> (Data, String)?) { self.resolve = resolve }

        mutating func flush() {
            let runs = Inlines.normalized(pending)
            pending = []
            if !runs.isEmpty { out.append(.paragraph(runs)) }
        }

        static let blockNames: Set<String> = [
            "p", "div", "section", "article", "main", "header", "footer", "aside", "figure", "figcaption",
            "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "hr", "table",
            "body", "html", "dl", "dt", "dd", "address", "center", "nav", "form", "fieldset", "details", "summary",
        ]
        static let skipped: Set<String> = ["script", "style", "head", "noscript", "template", "svg", "math", "button", "input", "select", "textarea", "iframe"]

        mutating func blocks(in node: XMLNode) {
            for child in node.children ?? [] {
                guard let element = child as? XMLElement else {
                    if child.kind == .text, let text = child.stringValue { pending.append(Inline(text: text)) }
                    continue
                }
                let name = element.localName?.lowercased() ?? ""
                if Self.skipped.contains(name) { continue }
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                    let runs = Inlines.normalized(inlines(element, style: Inline(text: "")))
                    if !runs.isEmpty { out.append(.heading(Int(String(name.dropFirst())) ?? 1, runs)) }
                case "p", "dt", "dd", "figcaption", "summary", "address":
                    flush()
                    if let image = soleImage(element) { out.append(image); continue }
                    let runs = Inlines.normalized(inlines(element, style: Inline(text: "", italic: name == "figcaption")))
                    if !runs.isEmpty { out.append(.paragraph(runs)) }
                case "ul", "ol":
                    flush()
                    list(element, ordered: name == "ol", depth: 0)
                case "blockquote":
                    flush()
                    var inner = Walker(resolve: resolve)
                    inner.blocks(in: element)
                    inner.flush()
                    for block in inner.out {
                        switch block {
                        case let .paragraph(runs), let .heading(_, runs), let .quote(runs): out.append(.quote(runs))
                        case let .listItem(_, _, _, runs): out.append(.quote(runs))
                        default: out.append(block)
                        }
                    }
                case "pre":
                    flush()
                    var text = element.stringValue ?? ""
                    if text.hasPrefix("\n") { text.removeFirst() }
                    while text.hasSuffix("\n") { text.removeLast() }
                    out.append(.code(text))
                case "hr":
                    flush()
                    out.append(.rule)
                case "table":
                    flush()
                    let rows = tableRows(element)
                    if !rows.isEmpty { out.append(.table(rows)) }
                case "img":
                    if let block = image(element) { flush(); out.append(block) }
                case "br":
                    pending.append(Inline(text: "\n"))
                default:
                    if Self.blockNames.contains(name) {
                        flush()
                        blocks(in: element)
                        flush()
                    } else {
                        pending += inlines(element, style: Inline(text: ""))
                    }
                }
            }
        }

        mutating func list(_ element: XMLElement, ordered: Bool, depth: Int) {
            var number = Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1
            for child in element.children ?? [] {
                guard let item = child as? XMLElement else { continue }
                let name = item.localName?.lowercased() ?? ""
                if name == "ul" || name == "ol" {
                    list(item, ordered: name == "ol", depth: depth + 1)
                    continue
                }
                guard name == "li" else { continue }
                var runs: [Inline] = []
                var nested: [(XMLElement, Bool)] = []
                for part in item.children ?? [] {
                    if let e = part as? XMLElement, let n = e.localName?.lowercased(), n == "ul" || n == "ol" {
                        nested.append((e, n == "ol"))
                    } else if let e = part as? XMLElement, e.localName?.lowercased() == "p" {
                        if !runs.isEmpty { runs.append(Inline(text: " ")) }
                        runs += inlines(e, style: Inline(text: ""))
                    } else if let e = part as? XMLElement {
                        runs += inlines(e, style: Inline(text: ""))
                    } else if part.kind == .text, let text = part.stringValue {
                        runs.append(Inline(text: text))
                    }
                }
                out.append(.listItem(ordered: ordered, depth: depth, number: number, Inlines.normalized(runs)))
                number += 1
                for (list, isOrdered) in nested { self.list(list, ordered: isOrdered, depth: depth + 1) }
            }
        }

        func tableRows(_ table: XMLElement) -> [[[Inline]]] {
            var rows: [[[Inline]]] = []
            func collect(_ node: XMLNode) {
                for child in node.children ?? [] {
                    guard let e = child as? XMLElement else { continue }
                    switch e.localName?.lowercased() ?? "" {
                    case "thead", "tbody", "tfoot": collect(e)
                    case "tr":
                        var cells: [[Inline]] = []
                        for cell in e.children ?? [] {
                            guard let c = cell as? XMLElement, let n = c.localName?.lowercased(), n == "td" || n == "th" else { continue }
                            cells.append(Inlines.normalized(inlines(c, style: Inline(text: ""))))
                            let span = Int(c.attribute(forName: "colspan")?.stringValue ?? "") ?? 1
                            if span > 1 { cells += Array(repeating: [], count: min(span - 1, 50)) }
                        }
                        rows.append(cells)
                    default: break
                    }
                }
            }
            collect(table)
            let width = rows.map(\.count).max() ?? 0
            return rows.map { $0 + Array(repeating: [], count: max(0, width - $0.count)) }
        }

        func soleImage(_ element: XMLElement) -> Block? {
            let text = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty else { return nil }
            let elements = (element.children ?? []).compactMap { $0 as? XMLElement }
            guard elements.count == 1, let img = elements.first, img.localName?.lowercased() == "img" else { return nil }
            return image(img)
        }

        func image(_ element: XMLElement) -> Block? {
            guard let src = element.attribute(forName: "src")?.stringValue, let (data, ext) = resolve(src) else { return nil }
            return .image(data, ext: ext, alt: element.attribute(forName: "alt")?.stringValue ?? "")
        }

        func inlines(_ node: XMLNode, style: Inline) -> [Inline] {
            var runs: [Inline] = []
            for child in node.children ?? [] {
                if child.kind == .text, let text = child.stringValue {
                    var run = style
                    run.text = text
                    runs.append(run)
                    continue
                }
                guard let e = child as? XMLElement else { continue }
                let name = e.localName?.lowercased() ?? ""
                if Self.skipped.contains(name) { continue }
                var s = style
                switch name {
                case "strong", "b": s.bold = true
                case "em", "i", "cite", "dfn", "var": s.italic = true
                case "code", "kbd", "samp", "tt": s.code = true
                case "s", "del", "strike": s.strike = true
                case "a":
                    if let href = e.attribute(forName: "href")?.stringValue, !href.hasPrefix("#") { s.link = href }
                case "br":
                    var run = style
                    run.text = "\n"
                    runs.append(run)
                    continue
                case "img":
                    if let alt = e.attribute(forName: "alt")?.stringValue, !alt.isEmpty {
                        var run = style
                        run.text = alt
                        runs.append(run)
                    }
                    continue
                default:
                    if Self.blockNames.contains(name) {
                        var run = style
                        run.text = " "
                        runs.append(run)
                    }
                }
                runs += inlines(e, style: s)
            }
            return runs
        }
    }

    // MARK: Writing

    static let stylesheet = """
    :root { color-scheme: light dark; }
    body { font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
           max-width: 44em; margin: 3em auto; padding: 0 1.25em; color: #1d1d1b; background: #fff; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 .5em; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.2em; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
    a { color: #c94a17; }
    code { font: .88em ui-monospace, Menlo, monospace; background: #f3f2ee; padding: .1em .3em; border-radius: 4px; }
    pre { background: #f3f2ee; padding: 1em; border-radius: 8px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #e2e0da; color: #5d5c58; }
    img { max-width: 100%; height: auto; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #dddbd5; padding: .4em .7em; text-align: left; vertical-align: top; }
    hr { border: 0; border-top: 1px solid #e2e0da; margin: 2em 0; }
    @media (prefers-color-scheme: dark) {
      body { background: #161615; color: #ecebe7; }
      code, pre { background: #262624; }
      blockquote { border-color: #3a3a37; color: #b5b3ad; }
      th, td { border-color: #3a3a37; }
    }
    """

    /// A standalone page. Images are embedded, or referenced by `imagePath` when it's given.
    static func write(_ doc: DocModel, xhtml: Bool = false, imagePath: ((Int, String) -> String)? = nil,
                      stylesheetHref: String? = nil) -> String {
        var body = ""
        var imageIndex = 0
        var openLists: [(ordered: Bool, depth: Int)] = []

        func closeLists(to depth: Int) {
            while let last = openLists.last, last.depth >= depth {
                body += last.ordered ? "</ol>\n" : "</ul>\n"
                openLists.removeLast()
            }
        }

        for block in doc.blocks {
            if case let .listItem(ordered, depth, number, runs) = block {
                if let last = openLists.last, last.depth > depth { closeLists(to: depth + 1) }
                if let last = openLists.last, last.depth == depth, last.ordered != ordered { closeLists(to: depth) }
                while (openLists.last?.depth ?? -1) < depth {
                    let d = (openLists.last?.depth ?? -1) + 1
                    let start = ordered && number > 1 && d == depth ? " start=\"\(number)\"" : ""
                    body += ordered ? "<ol\(start)>\n" : "<ul>\n"
                    openLists.append((ordered, d))
                }
                body += "<li>\(inline(runs, xhtml: xhtml))</li>\n"
                continue
            }
            closeLists(to: 0)
            switch block {
            case let .heading(level, runs):
                let l = min(6, max(1, level))
                body += "<h\(l)>\(inline(runs, xhtml: xhtml))</h\(l)>\n"
            case let .paragraph(runs):
                body += "<p>\(inline(runs, xhtml: xhtml))</p>\n"
            case let .quote(runs):
                body += "<blockquote><p>\(inline(runs, xhtml: xhtml))</p></blockquote>\n"
            case let .code(text):
                body += "<pre><code>\(text.xmlEscaped)</code></pre>\n"
            case .rule:
                body += xhtml ? "<hr/>\n" : "<hr>\n"
            case let .image(data, ext, alt):
                imageIndex += 1
                let src = imagePath?(imageIndex, ext)
                    ?? "data:\(Resources.mime(forExt: ext));base64,\(data.base64EncodedString())"
                body += "<p><img src=\"\(src.xmlEscaped)\" alt=\"\(alt.xmlEscaped)\"\(xhtml ? "/" : "")></p>\n"
            case let .table(rows):
                body += "<table>\n"
                for (r, row) in rows.enumerated() {
                    let tag = r == 0 && rows.count > 1 ? "th" : "td"
                    body += "<tr>" + row.map { "<\(tag)>\(inline($0, xhtml: xhtml))</\(tag)>" }.joined() + "</tr>\n"
                }
                body += "</table>\n"
            case .pageBreak:
                body += "<div style=\"page-break-after: always\"></div>\n"
            case .listItem:
                break
            }
        }
        closeLists(to: 0)

        let css = stylesheetHref.map { "<link rel=\"stylesheet\" href=\"\($0)\"\(xhtml ? "/" : "")>" }
            ?? "<style>\n\(stylesheet)\n</style>"
        if xhtml {
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
            <head>
            <meta charset="UTF-8"/>
            <title>\(doc.title.xmlEscaped)</title>
            \(css)
            </head>
            <body>
            \(body)</body>
            </html>
            """
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(doc.title.xmlEscaped)</title>
        \(css)
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }

    static func inline(_ runs: [Inline], xhtml: Bool) -> String {
        Inlines.merged(runs).map { run in
            var t = run.text.xmlEscaped.replacingOccurrences(of: "\n", with: xhtml ? "<br/>" : "<br>")
            if run.code { t = "<code>\(t)</code>" }
            if run.strike { t = "<del>\(t)</del>" }
            if run.italic { t = "<em>\(t)</em>" }
            if run.bold { t = "<strong>\(t)</strong>" }
            if let link = run.link { t = "<a href=\"\(link.xmlEscaped)\">\(t)</a>" }
            return t
        }.joined()
    }
}
