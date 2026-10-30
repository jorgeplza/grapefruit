import Foundation

/// A run of text with simple styling.
struct Inline: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String?
    // Typography a source brought along (Word, RTF). Page layouts use it; structural formats drop it.
    var font: String?
    var size: Double?
    /// "RRGGBB".
    var color: String?
    var underline = false

    func sameStyle(as other: Inline) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code && strike == other.strike && link == other.link
            && font == other.font && size == other.size && color == other.color && underline == other.underline
    }

    /// The run without typography, for formats that only carry structure.
    var structural: Inline {
        var run = self
        run.font = nil
        run.size = nil
        run.color = nil
        run.underline = false
        return run
    }
}

enum TextAlign {
    case left, center, right, justified
}

/// A document reduced to the structure every format can express.
enum Block {
    case heading(Int, [Inline])
    case paragraph([Inline])
    case listItem(ordered: Bool, depth: Int, number: Int, [Inline])
    case quote([Inline])
    case code(String)
    case rule
    case image(Data, ext: String, alt: String)
    case table([[[Inline]]])
    case pageBreak

    /// The same block with every run passed through `transform`.
    func mapRuns(_ transform: ([Inline]) -> [Inline]) -> Block {
        switch self {
        case let .heading(level, runs): .heading(level, transform(runs))
        case let .paragraph(runs): .paragraph(transform(runs))
        case let .listItem(ordered, depth, number, runs): .listItem(ordered: ordered, depth: depth, number: number, transform(runs))
        case let .quote(runs): .quote(transform(runs))
        case let .table(rows): .table(rows.map { $0.map(transform) })
        case .code, .rule, .image, .pageBreak: self
        }
    }
}

struct DocModel {
    var title: String
    var blocks: [Block]
    /// Paragraph alignment from the source, by block index. Only page layouts use it.
    var alignments: [Int: TextAlign] = [:]

    var images: [(Data, String)] {
        blocks.compactMap { if case let .image(data, ext, _) = $0 { return (data, ext) } else { return nil } }
    }

    /// The document without typography or alignment, for Markdown, HTML, EPUB and text.
    var structural: DocModel {
        DocModel(title: title, blocks: blocks.map { $0.mapRuns { Inlines.merged($0.map(\.structural)) } })
    }
}

enum Inlines {
    static func plain(_ runs: [Inline]) -> String {
        runs.map(\.text).joined()
    }

    /// Joins neighbours with the same style and drops empty runs.
    static func merged(_ runs: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.sameStyle(as: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// Collapses whitespace like a browser and trims the ends.
    static func normalized(_ runs: [Inline]) -> [Inline] {
        var out: [Inline] = []
        var lastWasSpace = true
        for var run in merged(runs) {
            if run.code {
                out.append(run)
                lastWasSpace = run.text.last?.isWhitespace ?? lastWasSpace
                continue
            }
            var text = ""
            for ch in run.text {
                if ch == "\n" {
                    // Explicit line breaks survive.
                    while text.last == " " { text.removeLast() }
                    text.append("\n")
                    lastWasSpace = true
                } else if ch.isWhitespace {
                    if !lastWasSpace { text.append(" ") }
                    lastWasSpace = true
                } else {
                    text.append(ch)
                    lastWasSpace = false
                }
            }
            run.text = text
            out.append(run)
        }
        // Trim the end.
        while let last = out.last {
            let trimmed = last.code ? last.text : String(last.text.reversed().drop(while: { $0 == " " || $0 == "\n" }).reversed())
            if trimmed.isEmpty { out.removeLast(); continue }
            out[out.count - 1].text = trimmed
            break
        }
        // Trim the start.
        while let first = out.first, !first.code {
            let trimmed = String(first.text.drop(while: { $0 == " " || $0 == "\n" }))
            if trimmed.isEmpty { out.removeFirst(); continue }
            out[0].text = trimmed
            break
        }
        return merged(out)
    }
}

// MARK: - Plain text

enum PlainText {
    /// Paragraphs are separated by blank lines; single line breaks are kept.
    static func read(_ text: String, title: String) -> DocModel {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [Block] = []
        for chunk in normalized.components(separatedBy: "\n\n") {
            let trimmed = chunk.trimmingCharacters(in: .newlines)
            guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if trimmed.contains("\u{0C}") {
                for (i, part) in trimmed.components(separatedBy: "\u{0C}").enumerated() {
                    if i > 0 { blocks.append(.pageBreak) }
                    if !part.isEmpty { blocks.append(.paragraph([Inline(text: part)])) }
                }
            } else {
                blocks.append(.paragraph([Inline(text: trimmed)]))
            }
        }
        return DocModel(title: title, blocks: blocks)
    }

    static func write(_ doc: DocModel) -> String {
        var parts: [(text: String, isList: Bool)] = []
        for block in doc.blocks {
            switch block {
            case let .heading(_, runs):
                parts.append((Inlines.plain(runs), false))
            case let .paragraph(runs):
                parts.append((Inlines.plain(runs), false))
            case let .listItem(ordered, depth, number, runs):
                let indent = String(repeating: "    ", count: depth)
                parts.append((indent + (ordered ? "\(number). " : "• ") + Inlines.plain(runs), true))
            case let .quote(runs):
                parts.append((Inlines.plain(runs).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    " + $0 }.joined(separator: "\n"), false))
            case let .code(text):
                parts.append((text, false))
            case .rule:
                parts.append(("* * *", false))
            case .image(_, _, let alt):
                if !alt.isEmpty { parts.append(("[\(alt)]", false)) }
            case let .table(rows):
                parts.append((rows.map { $0.map { Inlines.plain($0).replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\t") }.joined(separator: "\n"), false))
            case .pageBreak:
                parts.append(("\u{0C}", false))
            }
        }
        // List items sit on consecutive lines; everything else gets a blank line between.
        var text = ""
        var previousWasList = false
        for (i, part) in parts.enumerated() where !part.text.isEmpty {
            if i > 0 && !text.isEmpty { text += (part.isList && previousWasList) ? "\n" : "\n\n" }
            text += part.text
            previousWasList = part.isList
        }
        return text + "\n"
    }
}
