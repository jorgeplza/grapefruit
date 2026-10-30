import Foundation

/// EPUB 3 books in and out.
enum EPUB {
    // MARK: Reading

    static func read(_ url: URL, title fallback: String) throws -> DocModel {
        let zip = try ZipReader(url: url)
        let container = try XMLDocument(data: zip.read("META-INF/container.xml"))
        guard let rootPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw JobError.failed("This EPUB has no table of contents.")
        }
        let opf = try XMLDocument(data: zip.read(rootPath))
        let base = (rootPath as NSString).deletingLastPathComponent

        var manifest: [String: (href: String, type: String, properties: String)] = [:]
        for node in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let e = node as? XMLElement, let id = e.attribute(forName: "id")?.stringValue,
                  let href = e.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = (href.removingPercentEncoding ?? href, e.attribute(forName: "media-type")?.stringValue ?? "",
                            e.attribute(forName: "properties")?.stringValue ?? "")
        }
        let spine = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref").compactMap(\.stringValue)
        let title = try opf.nodes(forXPath: "//*[local-name()='title']").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback

        var blocks: [Block] = []
        for (index, id) in spine.enumerated() {
            guard let item = manifest[id], !item.properties.contains("nav") else { continue }
            let path = join(base, item.href)
            guard let data = try? zip.read(path) else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            let chapter = HTMLDoc.read(data, title: title) { src in
                guard !src.hasPrefix("http") else { return nil }
                if src.hasPrefix("data:") { return Resources.load(src, relativeTo: nil) }
                let imagePath = join(folder, src.removingPercentEncoding ?? src)
                guard let bytes = try? zip.read(imagePath) else { return nil }
                let ext = (imagePath as NSString).pathExtension.lowercased()
                return (bytes, ext == "jpeg" ? "jpg" : (ext.isEmpty ? "png" : ext))
            }
            if index > 0 && !blocks.isEmpty && !chapter.blocks.isEmpty { blocks.append(.pageBreak) }
            blocks += chapter.blocks
        }
        return DocModel(title: title.isEmpty ? fallback : title, blocks: blocks)
    }

    /// Resolves "../images/a.png" against a folder inside the package.
    static func join(_ folder: String, _ relative: String) -> String {
        var parts = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
        let clean = relative.split(separator: "#").first.map(String.init) ?? relative
        for piece in clean.split(separator: "/") {
            if piece == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: Writing

    static func write(_ doc: DocModel, to url: URL) throws {
        // Chapters start at each top-level heading.
        let topLevel = doc.blocks.compactMap { block -> Int? in
            if case let .heading(level, _) = block { return level } else { return nil }
        }.min() ?? 1
        var chapters: [[Block]] = [[]]
        for block in doc.blocks {
            if case .pageBreak = block {
                if !(chapters.last?.isEmpty ?? true) { chapters.append([]) }
                continue
            }
            if case let .heading(level, _) = block, level == topLevel, !(chapters.last?.isEmpty ?? true) {
                chapters.append([])
            }
            chapters[chapters.count - 1].append(block)
        }
        chapters = chapters.filter { !$0.isEmpty }
        if chapters.isEmpty { chapters = [[.paragraph([Inline(text: " ")])]] }

        let zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """)
        zip.add("OEBPS/style.css", HTMLDoc.stylesheet
            .replacingOccurrences(of: "max-width: 44em; margin: 3em auto; padding: 0 1.25em;", with: "margin: 0; padding: 0;")
            .replacingOccurrences(of: ":root { color-scheme: light dark; }\n", with: ""))

        var manifest: [String] = []
        var spine: [String] = []
        var toc: [(title: String, file: String)] = []
        var imageCount = 0

        for (i, blocks) in chapters.enumerated() {
            let file = "chapter-\(i + 1).xhtml"
            let chapterTitle = blocks.lazy.compactMap { block -> String? in
                if case let .heading(_, runs) = block { return Inlines.plain(runs) } else { return nil }
            }.first ?? (chapters.count == 1 ? doc.title : "Part \(i + 1)")
            var chapterDoc = DocModel(title: chapterTitle, blocks: blocks)
            var imageFiles: [(String, Data)] = []
            for case let .image(data, ext, _) in blocks {
                imageCount += 1
                imageFiles.append(("images/image-\(imageCount).\(ext)", data))
            }
            var localIndex = 0
            let firstImage = imageCount - imageFiles.count
            let html = HTMLDoc.write(chapterDoc, xhtml: true, imagePath: { _, ext in
                localIndex += 1
                return "images/image-\(firstImage + localIndex).\(ext)"
            }, stylesheetHref: "style.css")
            chapterDoc.blocks = []
            zip.add("OEBPS/\(file)", html)
            for (path, data) in imageFiles {
                zip.add("OEBPS/\(path)", data, compress: false)
                let ext = (path as NSString).pathExtension
                manifest.append("<item id=\"img\(manifest.count)\" href=\"\(path)\" media-type=\"\(Resources.mime(forExt: ext))\"/>")
            }
            manifest.append("<item id=\"c\(i + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>")
            spine.append("<itemref idref=\"c\(i + 1)\"/>")
            toc.append((chapterTitle, file))
        }

        let navItems = toc.map { "<li><a href=\"\($0.file)\">\($0.title.xmlEscaped)</a></li>" }.joined(separator: "\n      ")
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
        <head><meta charset="UTF-8"/><title>\(doc.title.xmlEscaped)</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>Contents</h1>
            <ol>
              \(navItems)
            </ol>
          </nav>
        </body>
        </html>
        """)

        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let navPoints = toc.enumerated().map { i, entry in
            "<navPoint id=\"n\(i + 1)\" playOrder=\"\(i + 1)\"><navLabel><text>\(entry.title.xmlEscaped)</text></navLabel><content src=\"\(entry.file)\"/></navPoint>"
        }.joined(separator: "\n    ")
        zip.add("OEBPS/toc.ncx", """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="\(identifier)"/></head>
          <docTitle><text>\(doc.title.xmlEscaped)</text></docTitle>
          <navMap>
            \(navPoints)
          </navMap>
        </ncx>
        """)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(identifier)</dc:identifier>
            <dc:title>\(doc.title.xmlEscaped)</dc:title>
            <dc:language>\(Locale.current.language.languageCode?.identifier ?? "en")</dc:language>
            <meta property="dcterms:modified">\(formatter.string(from: Date()))</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifest.joined(separator: "\n    "))
          </manifest>
          <spine toc="ncx">
            \(spine.joined(separator: "\n    "))
          </spine>
        </package>
        """)
        try zip.write(to: url)
    }
}
