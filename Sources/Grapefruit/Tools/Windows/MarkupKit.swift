import AppKit
import ImageIO
import SwiftUI

/// Shared by Annotate Photo and Create Collage. Everything sits under this one name so it
/// can't clash with other tools: image loading, the drawing code that both the live canvas
/// and the saved file use (so they always match), the collage layout, and a few small
/// controls drawn in the tool windows' style.
enum MarkupKit {}

// MARK: - Geometry

extension MarkupKit {
    /// `size` scaled to fit inside `bounds`, centered. `maxScale` keeps small images from being blown up.
    static func fit(_ size: CGSize, in bounds: CGRect, maxScale: CGFloat = .greatestFiniteMagnitude) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height, maxScale)
        let w = size.width * s, h = size.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// `size` scaled to cover `bounds`, centered. The overflow is what gets cropped.
    static func cover(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let s = max(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Shortest distance from `p` to the segment from `a` to `b`.
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rounds a rect's edges to whole pixels so neighbouring cells never leave hairline seams.
    static func snapped(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        let x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }
}

// MARK: - Colors

extension MarkupKit {
    /// An sRGB color that can cross threads and be compared.
    struct RGBA: Hashable, Sendable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat

        init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(_ hex: UInt32, alpha: CGFloat = 1) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
            a = alpha
        }

        var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

        func alpha(_ value: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: value) }

        /// Relative luminance, 0 for black and 1 for white.
        var luminance: CGFloat {
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// Light enough that white text on it would be hard to read.
        var isLight: Bool { luminance > 0.5 }
        /// Dark enough that a dark shadow wouldn't show: it gets a light halo instead.
        var isDark: Bool { luminance < 0.12 }
    }

    struct Swatch: Identifiable, Hashable, Sendable {
        let name: String
        /// nil is "transparent".
        let color: RGBA?
        var id: String { name }
    }

    /// Ink for annotations: Apple's system hues, fixed so the saved file never depends on the theme.
    static let inkSwatches: [Swatch] = [
        Swatch(name: "Red", color: RGBA(0xFF3B30)),
        Swatch(name: "Orange", color: RGBA(0xFF9500)),
        Swatch(name: "Yellow", color: RGBA(0xFFCC00)),
        Swatch(name: "Green", color: RGBA(0x34C759)),
        Swatch(name: "Mint", color: RGBA(0x00C7BE)),
        Swatch(name: "Blue", color: RGBA(0x007AFF)),
        Swatch(name: "Indigo", color: RGBA(0x5856D6)),
        Swatch(name: "Pink", color: RGBA(0xFF2D55)),
        Swatch(name: "White", color: RGBA(0xFFFFFF)),
        Swatch(name: "Black", color: RGBA(0x1C1C1E)),
    ]

    static let red = RGBA(0xFF3B30)
    static let yellow = RGBA(0xFFCC00)
    static let white = RGBA(0xFFFFFF)
}

// MARK: - Pictures

extension MarkupKit {
    /// A picture ready to show: downscaled and upright, plus what we know about the original.
    struct Picture: @unchecked Sendable {
        let image: CGImage
        /// The original's upright size in pixels.
        let pixelSize: CGSize
        let hasAlpha: Bool

        var aspect: CGFloat { pixelSize.width / max(1, pixelSize.height) }
        var isWideGamut: Bool { image.colorSpace?.isWideGamutRGB ?? false }
    }

    static func isSVG(_ url: URL) -> Bool {
        Catalog.format(of: url) == "svg"
    }

    /// The upright pixel size without decoding any pixels. Cheap enough to call for 20 files at once.
    static func probe(_ url: URL) -> CGSize? {
        if isSVG(url) {
            guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else { return nil }
            return svg.size
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// An upright copy whose longest side is at most `maxPixel`. Never scales up.
    static func picture(_ url: URL, maxPixel: Int) throws -> Picture {
        if isSVG(url) {
            let loaded = try ImageEngine.load(url, format: "svg", minimumSide: CGFloat(maxPixel))
            let image = ImageEngine.resized(loaded.image, maxSide: maxPixel)
            let natural = NSImage(contentsOf: url)?.size ?? CGSize(width: image.width, height: image.height)
            return Picture(image: image, pixelSize: natural, hasAlpha: true)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw JobError.failed("Couldn't read this image.")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw JobError.failed("Couldn't decode this image.")
        }
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&w, &h) }
        if w <= 0 || h <= 0 { w = Double(image.width); h = Double(image.height) }
        let alpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? true
        }
        return Picture(image: image, pixelSize: CGSize(width: w, height: h), hasAlpha: alpha)
    }

    /// A color space a bitmap context can draw into that keeps the photo's colors.
    static func workingSpace(for image: CGImage?) -> CGColorSpace {
        if let space = image?.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func bitmap(width: Int, height: Int, space: CGColorSpace, opaque: Bool) -> CGContext? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: space, bitmapInfo: info) { return ctx }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }
}

// MARK: - Annotations

extension MarkupKit {
    enum MarkTool: String, CaseIterable, Identifiable, Sendable {
        case arrow, pen, text, rectangle, ellipse, highlighter, number, magnifier, image

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .arrow: "arrow.up.left"
            case .pen: "pencil.tip"
            case .text: "textformat"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .highlighter: "highlighter"
            case .number: "1.circle"
            case .magnifier: "plus.magnifyingglass"
            case .image: "photo.badge.plus"
            }
        }

        var title: String {
            switch self {
            case .arrow: "Arrow"
            case .pen: "Pen"
            case .text: "Text"
            case .rectangle: "Rectangle"
            case .ellipse: "Ellipse"
            case .highlighter: "Highlighter"
            case .number: "Numbered callout"
            case .magnifier: "Magnifier"
            case .image: "Place image"
            }
        }

        /// Single-key shortcut while the canvas has focus.
        var key: String {
            switch self {
            case .arrow: "a"
            case .pen: "p"
            case .text: "t"
            case .rectangle: "r"
            case .ellipse: "o"
            case .highlighter: "h"
            case .number: "n"
            case .magnifier: "m"
            case .image: "i"
            }
        }

        /// Small, medium and large, in canvas points: line width, text size or callout diameter.
        /// Small is the default; a 2 pt line matches the original's arrows.
        var sizes: [CGFloat] {
            switch self {
            case .arrow, .pen, .rectangle, .ellipse: [2, 3.5, 6]
            case .highlighter: [14, 20, 30]
            case .text: [16, 22, 32]
            case .number: [22, 28, 36]
            case .magnifier, .image: [1, 1, 1]
            }
        }

        var usesInk: Bool { self != .magnifier && self != .image }
    }

    /// A placed image, shared by reference so undo snapshots stay cheap.
    final class PlacedImage: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// One annotation. Geometry is in the photo's pixels with y pointing down;
    /// `size` is in canvas points and gets multiplied by `MarkDoc.unit` when drawn.
    struct Mark: Identifiable, Equatable, @unchecked Sendable {
        var id = UUID()
        var tool: MarkTool
        var color: RGBA
        /// Line width, text size or callout diameter, in canvas points.
        var size: CGFloat
        /// arrow: tail then head. pen and highlighter: the stroke. number: the center.
        var points: [CGPoint] = []
        /// rectangle, ellipse, image and magnifier: the frame. text: the top-left corner and measured size.
        var rect: CGRect = .zero
        var text = ""
        /// magnifier only.
        var zoom: CGFloat = 2
        var picture: PlacedImage?

        static func == (a: Mark, b: Mark) -> Bool {
            a.id == b.id && a.tool == b.tool && a.color == b.color && a.size == b.size && a.points == b.points
                && a.rect == b.rect && a.text == b.text && a.zoom == b.zoom && a.picture === b.picture
        }

        func moved(by d: CGVector) -> Mark {
            var m = self
            m.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
            m.rect = rect.offsetBy(dx: d.dx, dy: d.dy)
            return m
        }
    }

    struct MarkDoc: Equatable, @unchecked Sendable {
        /// The upright photo's size in pixels.
        var pixelSize: CGSize
        /// Photo pixels per canvas point: how big a "3 pt" line really is in the saved file.
        var unit: CGFloat
        var marks: [Mark] = []
    }

    /// Drawing for annotations. The canvas and the export both call `draw`, so what you see is what gets saved.
    enum Ink {
        static let highlightAlpha: CGFloat = 0.42

        enum Handle: Hashable {
            case tail, head, radius
            /// 0 top left, 1 top right, 2 bottom right, 3 bottom left.
            case corner(Int)
        }

        // MARK: Drawing

        /// Draws the photo and every mark. `ctx` must already map the photo's pixels with y pointing down.
        /// `lens` is what magnifiers enlarge (the photo by default), so the canvas can paint a light
        /// screen-sized photo underneath and keep the sharp one for zooming.
        static func draw(_ doc: MarkDoc, photo: CGImage?, lens: CGImage? = nil, in ctx: CGContext, hiding hidden: UUID? = nil) {
            if let photo { drawImage(photo, in: CGRect(origin: .zero, size: doc.pixelSize), ctx: ctx) }
            let numbers = numbering(doc.marks)
            drawMarks(doc.marks[...], doc: doc, photo: lens ?? photo, numbers: numbers, hidden: hidden, ctx: ctx)
        }

        /// Callouts count up in the order they were placed, so deleting one renumbers the rest.
        static func numbering(_ marks: [Mark]) -> [UUID: Int] {
            var result: [UUID: Int] = [:]
            var n = 0
            for m in marks where m.tool == .number {
                n += 1
                result[m.id] = n
            }
            return result
        }

        private static func drawMarks(_ marks: ArraySlice<Mark>, doc: MarkDoc, photo: CGImage?,
                                      numbers: [UUID: Int], hidden: UUID?, ctx: CGContext) {
            let unit = doc.unit
            for i in marks.indices {
                let m = marks[i]
                if m.id == hidden { continue }
                ctx.saveGState()
                switch m.tool {
                case .arrow:
                    if m.points.count >= 2 { stroke(arrowPath(m, unit: unit), m, unit: unit, ctx: ctx) }
                case .pen:
                    stroke(smoothPath(m.points), m, unit: unit, ctx: ctx)
                case .rectangle:
                    stroke(rectanglePath(m, unit: unit), m, unit: unit, ctx: ctx)
                case .ellipse:
                    stroke(CGPath(ellipseIn: m.rect.standardized, transform: nil), m, unit: unit, ctx: ctx)
                case .highlighter:
                    ctx.addPath(smoothPath(m.points))
                    ctx.setLineWidth(max(1, m.size * unit))
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.setStrokeColor(m.color.alpha(highlightAlpha).cg)
                    ctx.strokePath()
                case .text:
                    drawText(m, unit: unit, ctx: ctx)
                case .number:
                    drawNumber(m, number: numbers[m.id] ?? 1, unit: unit, ctx: ctx)
                case .magnifier:
                    drawMagnifier(m, below: marks[marks.startIndex..<i], doc: doc, photo: photo,
                                  numbers: numbers, hidden: hidden, ctx: ctx)
                case .image:
                    if let picture = m.picture {
                        ctx.interpolationQuality = .high
                        drawImage(picture.image, in: m.rect.standardized, ctx: ctx)
                    }
                }
                ctx.restoreGState()
            }
        }

        /// Draws a CGImage right side up into a y-down context.
        static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }

        /// Device pixels per user-space unit. Shadows are measured in device space, so they need this.
        static func deviceScale(_ ctx: CGContext) -> CGFloat {
            let t = ctx.userSpaceToDeviceSpaceTransform
            return max(0.0001, sqrt(abs(t.a * t.d - t.b * t.c)))
        }

        /// A soft drop shadow so marks read on any photo. Dark ink gets a light halo instead.
        private static func shadow(_ ctx: CGContext, unit: CGFloat, size: CGFloat, ink: RGBA, strength: CGFloat = 1) {
            let k = deviceScale(ctx)
            let blur = (1.6 + min(size, 12) * 0.35) * unit * k * strength
            if ink.isDark {
                ctx.setShadow(offset: .zero, blur: blur, color: CGColor(gray: 1, alpha: 0.6))
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * unit * k * strength), blur: blur,
                              color: CGColor(gray: 0, alpha: min(0.5, 0.3 * strength)))
            }
        }

        private static func stroke(_ path: CGPath, _ m: Mark, unit: CGFloat, ctx: CGContext) {
            shadow(ctx, unit: unit, size: m.size, ink: m.color)
            ctx.addPath(path)
            ctx.setLineWidth(max(0.5, m.size * unit))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(m.color.cg)
            ctx.strokePath()
        }

        static func arrowHeadLength(_ m: Mark, unit: CGFloat) -> CGFloat {
            guard m.points.count >= 2 else { return 0 }
            let length = distance(m.points[0], m.points[1])
            // About 13 pt for a 2 pt line, like the original, growing with the line.
            return min(length * 0.5, (7 + 3 * m.size) * unit)
        }

        /// The shaft plus an open chevron, one path so it casts one shadow. The head grows with the line.
        static func arrowPath(_ m: Mark, unit: CGFloat) -> CGPath {
            let tail = m.points[0], head = m.points[1]
            let path = CGMutablePath()
            path.move(to: tail)
            path.addLine(to: head)
            let headLength = arrowHeadLength(m, unit: unit)
            guard headLength > 0.01 else { return path }
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            let spread = CGFloat.pi / 6
            let left = CGPoint(x: head.x - headLength * cos(angle - spread), y: head.y - headLength * sin(angle - spread))
            let right = CGPoint(x: head.x - headLength * cos(angle + spread), y: head.y - headLength * sin(angle + spread))
            path.move(to: left)
            path.addLine(to: head)
            path.addLine(to: right)
            return path
        }

        /// A freehand stroke smoothed through the midpoints of the samples.
        static func smoothPath(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            guard let first = points.first else { return path }
            path.move(to: first)
            if points.count < 3 {
                path.addLine(to: points.last ?? first)
                return path
            }
            for i in 1..<(points.count - 1) {
                let p = points[i], next = points[i + 1]
                path.addQuadCurve(to: CGPoint(x: (p.x + next.x) / 2, y: (p.y + next.y) / 2), control: p)
            }
            path.addLine(to: points[points.count - 1])
            return path
        }

        static func rectanglePath(_ m: Mark, unit: CGFloat) -> CGPath {
            let r = m.rect.standardized
            let radius = max(0, min((1.5 + m.size * 0.6) * unit, r.width / 2, r.height / 2))
            guard radius > 0.01 else { return CGPath(rect: r, transform: nil) }
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        // MARK: Text

        static func textFont(_ pointSize: CGFloat) -> NSFont {
            let size = max(1, pointSize)
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            if let rounded = base.fontDescriptor.withDesign(.rounded), let font = NSFont(descriptor: rounded, size: size) {
                return font
            }
            return base
        }

        static func textAttributes(_ m: Mark, unit: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: textFont(m.size * unit), .foregroundColor: m.color.ns]
        }

        /// The laid-out size of a text mark, in photo pixels.
        static func textSize(_ text: String, size: CGFloat, unit: CGFloat) -> CGSize {
            let string = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: textFont(size * unit)])
            let r = string.boundingRect(with: CGSize(width: 1e7, height: 1e7), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return CGSize(width: ceil(r.width), height: ceil(r.height))
        }

        private static func drawText(_ m: Mark, unit: CGFloat, ctx: CGContext) {
            guard !m.text.isEmpty else { return }
            shadow(ctx, unit: unit, size: 3, ink: m.color)
            let string = NSAttributedString(string: m.text, attributes: textAttributes(m, unit: unit))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            string.draw(with: CGRect(origin: m.rect.origin, size: CGSize(width: 1e7, height: 1e7)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }

        // MARK: Callouts and magnifier

        private static func drawNumber(_ m: Mark, number: Int, unit: CGFloat, ctx: CGContext) {
            guard let c = m.points.first else { return }
            let d = m.size * unit
            let disc = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            ctx.saveGState()
            shadow(ctx, unit: unit, size: 4, ink: m.color)
            ctx.setFillColor(m.color.cg)
            ctx.fillEllipse(in: disc)
            ctx.restoreGState()

            let ring = max(0.75 * unit, d * 0.075)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(ring)
            ctx.strokeEllipse(in: disc.insetBy(dx: ring / 2, dy: ring / 2))

            let label = "\(number)"
            let font = textFont(d * (label.count > 1 ? 0.44 : 0.54))
            let ink: NSColor = m.color.isLight ? NSColor(white: 0.12, alpha: 1) : .white
            let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
            let width = string.size().width
            // Center the cap height on the disc, which reads as optically centered.
            let top = c.y + font.capHeight / 2 - font.ascender
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            string.draw(with: CGRect(x: c.x - width / 2, y: top, width: width + 1, height: d * 2),
                        options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }

        /// A round lens that shows what's under it (the photo and earlier marks), zoomed around its center.
        private static func drawMagnifier(_ m: Mark, below: ArraySlice<Mark>, doc: MarkDoc, photo: CGImage?,
                                          numbers: [UUID: Int], hidden: UUID?, ctx: CGContext) {
            let r = m.rect.standardized
            guard r.width > 1 else { return }
            let unit = doc.unit
            let center = CGPoint(x: r.midX, y: r.midY)

            ctx.saveGState()
            shadow(ctx, unit: unit, size: 10, ink: RGBA(0x000000), strength: 1.4)
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
            ctx.fillEllipse(in: r)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addEllipse(in: r)
            ctx.clip()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: m.zoom, y: m.zoom)
            ctx.translateBy(x: -center.x, y: -center.y)
            ctx.interpolationQuality = .high
            if let photo { drawImage(photo, in: CGRect(origin: .zero, size: doc.pixelSize), ctx: ctx) }
            drawMarks(below, doc: doc, photo: photo, numbers: numbers, hidden: hidden, ctx: ctx)
            ctx.restoreGState()

            let rim = max(1.5 * unit, min(3.2 * unit, r.width * 0.045))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(rim)
            ctx.strokeEllipse(in: r.insetBy(dx: rim / 2, dy: rim / 2))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
            ctx.setLineWidth(0.6 * unit)
            ctx.strokeEllipse(in: r.insetBy(dx: -0.3 * unit, dy: -0.3 * unit))
        }

        // MARK: Geometry for selection

        /// What a mark covers, for selection outlines.
        static func bounds(_ m: Mark, unit: CGFloat) -> CGRect {
            let pad = m.size * unit / 2
            switch m.tool {
            case .arrow:
                let extra = pad + arrowHeadLength(m, unit: unit) * 0.5
                return boundingBox(m.points).insetBy(dx: -extra, dy: -extra)
            case .pen, .highlighter:
                return boundingBox(m.points).insetBy(dx: -pad, dy: -pad)
            case .rectangle, .ellipse:
                return m.rect.standardized.insetBy(dx: -pad, dy: -pad)
            case .image, .magnifier:
                return m.rect.standardized
            case .text:
                return CGRect(origin: m.rect.origin, size: textSize(m.text, size: m.size, unit: unit))
            case .number:
                let c = m.points.first ?? .zero, d = m.size * unit
                return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            }
        }

        /// Whether `p` (photo pixels) lands on the mark. Outlines only count their stroke, so you can still draw inside a box.
        static func hits(_ m: Mark, _ p: CGPoint, tolerance: CGFloat, unit: CGFloat) -> Bool {
            let reach = m.size * unit / 2 + tolerance
            switch m.tool {
            case .arrow:
                guard m.points.count >= 2 else { return false }
                if distance(p, toSegment: m.points[0], m.points[1]) <= reach { return true }
                let path = arrowPath(m, unit: unit)
                return path.copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p)
            case .pen, .highlighter:
                guard let first = m.points.first else { return false }
                if m.points.count == 1 { return distance(p, first) <= reach }
                for i in 1..<m.points.count where distance(p, toSegment: m.points[i - 1], m.points[i]) <= reach { return true }
                return false
            case .rectangle:
                let r = m.rect.standardized
                let outer = r.insetBy(dx: -reach, dy: -reach), inner = r.insetBy(dx: reach, dy: reach)
                return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
            case .ellipse:
                let r = m.rect.standardized
                let a = max(r.width / 2, 0.5), b = max(r.height / 2, 0.5)
                let dx = p.x - r.midX, dy = p.y - r.midY
                let k = sqrt((dx * dx) / (a * a) + (dy * dy) / (b * b))
                return abs(k - 1) * min(a, b) <= reach
            case .text, .image:
                return bounds(m, unit: unit).insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
            case .number, .magnifier:
                let r = bounds(m, unit: unit)
                return distance(p, CGPoint(x: r.midX, y: r.midY)) <= r.width / 2 + tolerance / 2
            }
        }

        static func handles(_ m: Mark) -> [(Handle, CGPoint)] {
            switch m.tool {
            case .arrow:
                guard m.points.count >= 2 else { return [] }
                return [(.tail, m.points[0]), (.head, m.points[1])]
            case .rectangle, .ellipse, .image:
                let r = m.rect.standardized
                return [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                        (.corner(2), CGPoint(x: r.maxX, y: r.maxY)), (.corner(3), CGPoint(x: r.minX, y: r.maxY))]
            case .magnifier:
                let r = m.rect.standardized
                let angle = CGFloat.pi / 4
                return [(.radius, CGPoint(x: r.midX + r.width / 2 * cos(angle), y: r.midY + r.height / 2 * sin(angle)))]
            default:
                return []
            }
        }

        /// The mark after dragging one of its handles to `p`. `constrain` is Shift: 45° arrows, squares and circles.
        static func resized(_ original: Mark, handle: Handle, to p: CGPoint, constrain: Bool, unit: CGFloat) -> Mark {
            var m = original
            switch handle {
            case .tail:
                m.points[0] = constrain ? snap45(from: original.points[1], to: p) : p
            case .head:
                m.points[1] = constrain ? snap45(from: original.points[0], to: p) : p
            case .radius:
                let r = original.rect.standardized
                let radius = min(max(distance(CGPoint(x: r.midX, y: r.midY), p), 14 * unit), 260 * unit)
                m.rect = CGRect(x: r.midX - radius, y: r.midY - radius, width: radius * 2, height: radius * 2)
            case .corner(let i):
                let r = original.rect.standardized
                let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                               CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                let anchor = corners[(i + 2) % 4]
                var w = p.x - anchor.x, h = p.y - anchor.y
                if original.tool == .image || constrain {
                    let aspect = original.tool == .image ? max(r.width, 1) / max(r.height, 1) : 1
                    let sx: CGFloat = w < 0 ? -1 : 1, sy: CGFloat = h < 0 ? -1 : 1
                    if abs(w) / aspect > abs(h) { h = sy * abs(w) / aspect } else { w = sx * abs(h) * aspect }
                }
                let minimum = 4 * unit
                if abs(w) < minimum { w = w < 0 ? -minimum : minimum }
                if abs(h) < minimum { h = h < 0 ? -minimum : minimum }
                m.rect = CGRect(x: anchor.x, y: anchor.y, width: w, height: h).standardized
            }
            return m
        }

        static func snap45(from a: CGPoint, to p: CGPoint) -> CGPoint {
            let length = distance(a, p)
            let step = CGFloat.pi / 4
            let angle = (atan2(p.y - a.y, p.x - a.x) / step).rounded() * step
            return CGPoint(x: a.x + length * cos(angle), y: a.y + length * sin(angle))
        }

        // MARK: Export

        /// The photo at full resolution with every mark burned in.
        static func render(_ doc: MarkDoc, photo: CGImage, opaque: Bool) throws -> CGImage {
            let w = photo.width, h = photo.height
            guard let ctx = bitmap(width: w, height: h, space: workingSpace(for: photo), opaque: opaque) else {
                throw JobError.failed("Not enough memory to draw this photo.")
            }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            // Marks were placed on the upright size measured when the window opened. If the
            // full decode came out different, stretch the marks to match.
            let sx = CGFloat(w) / max(1, doc.pixelSize.width), sy = CGFloat(h) / max(1, doc.pixelSize.height)
            if abs(sx - 1) > 0.0005 || abs(sy - 1) > 0.0005 { ctx.scaleBy(x: sx, y: sy) }
            draw(doc, photo: photo, in: ctx)
            guard let image = ctx.makeImage() else { throw JobError.failed("Couldn't draw the annotations.") }
            return image
        }

        /// Loads the original, burns in the marks and writes a PNG. Runs on the job queue.
        static func export(_ src: URL, doc: MarkDoc, to out: URL, job: JobContext) throws {
            job.progress(0.05)
            let loaded = try ImageEngine.load(src)
            try job.checkCancelled()
            job.progress(0.45)
            let opaque: Bool
            switch loaded.image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: opaque = true
            default: opaque = false
            }
            let image = try render(doc, photo: loaded.image, opaque: opaque)
            try job.checkCancelled()
            job.progress(0.75)
            // Keep the camera details, drop the location: annotated copies tend to get shared.
            var properties = loaded.properties
            properties[kCGImagePropertyGPSDictionary] = nil
            try ImageEngine.write(ImageEngine.Loaded(image: image, properties: properties, pointsPerPixel: loaded.pointsPerPixel),
                                  as: "png", to: out, keepMetadata: true)
            job.progress(1)
        }
    }
}

// MARK: - Collage

extension MarkupKit {
    enum CollageStyle: String, CaseIterable, Identifiable, Sendable {
        case grid, row, column, featured
        var id: String { rawValue }
        var title: String {
            switch self {
            case .grid: "Grid"
            case .row: "Row"
            case .column: "Column"
            case .featured: "Featured"
            }
        }
    }

    enum CollageCanvas: String, CaseIterable, Identifiable, Sendable {
        case square, portrait, story, landscape, wide, auto
        var id: String { rawValue }
        var title: String {
            switch self {
            case .square: "Square · 1:1"
            case .portrait: "Portrait · 4:5"
            case .story: "Story · 9:16"
            case .landscape: "Landscape · 3:2"
            case .wide: "Wide · 16:9"
            case .auto: "Fit the images"
            }
        }
        /// Width over height. nil means the canvas follows the images.
        var ratio: CGFloat? {
            switch self {
            case .square: 1
            case .portrait: 4.0 / 5.0
            case .story: 9.0 / 16.0
            case .landscape: 3.0 / 2.0
            case .wide: 16.0 / 9.0
            case .auto: nil
            }
        }
    }

    struct CollageSettings: Equatable, Sendable {
        static let widths = [1080, 1600, 2048, 3000, 4096]

        var style: CollageStyle = .grid
        var columns = 2
        var canvas: CollageCanvas = .square
        /// Output width in pixels.
        var width = 2048
        /// Fill cells and crop the edges, or fit whole images inside them.
        var fill = true
        /// Gap between images, margin around the edge and corner radius, as fractions of the
        /// canvas width so the look holds when the width changes.
        var spacing: CGFloat = 16.0 / 2048
        var margin: CGFloat = 24.0 / 2048
        var corners: CGFloat = 0
        /// nil is transparent.
        var background: RGBA? = RGBA(0xFFFFFF)

        var isOpaque: Bool { (background?.a ?? 0) >= 1 }

        /// The right number of columns to start with: a balanced grid.
        static func defaultColumns(for count: Int) -> Int {
            max(1, Int(ceil(sqrt(Double(max(1, count))))))
        }
    }

    struct CollageCell: Equatable, Sendable {
        /// The slot in the layout.
        var frame: CGRect
        /// What stays visible, rounded by `radius`.
        var clip: CGRect
        /// Where the whole image is drawn (bigger than the clip when cropping).
        var image: CGRect
        var radius: CGFloat
    }

    struct CollageLayout: Equatable, Sendable {
        /// Canvas size in output pixels.
        var size: CGSize
        /// One per image, in order.
        var cells: [CollageCell]
    }

    /// The collage layout and renderer. The window's preview and the saved file both come from `layout`.
    enum Collage {
        /// Biggest canvas we'll allocate, in pixels.
        static let maxPixels: CGFloat = 64_000_000

        static func layout(aspects raw: [CGFloat], settings s: CollageSettings) -> CollageLayout {
            let aspects = raw.map { $0.isFinite && $0 > 0 ? min(max($0, 0.05), 20) : 1 }
            let n = aspects.count
            let width = CGFloat(max(64, s.width))
            guard n > 0 else { return CollageLayout(size: CGSize(width: width, height: width), cells: []) }
            var gap = (max(0, s.spacing) * width).rounded()
            var margin = (max(0, s.margin) * width).rounded()
            // Never let spacing eat the pictures.
            margin = min(margin, (width * 0.2).rounded())
            gap = min(gap, (width * 0.1).rounded())

            let height = canvasHeight(aspects, settings: s, width: width, gap: gap, margin: margin)
            let area = CGRect(x: margin, y: margin, width: width - 2 * margin, height: max(1, height - 2 * margin))
            let frames = cellFrames(aspects, settings: s, area: area, gap: gap)
            let radius = max(0, s.corners) * width
            let cells = zip(frames, aspects).map { frame, aspect -> CollageCell in
                let picture = CGSize(width: aspect, height: 1)
                let drawn = s.fill ? cover(picture, in: frame) : fit(picture, in: frame)
                let clip = s.fill ? frame : drawn
                return CollageCell(frame: frame, clip: clip, image: drawn, radius: min(radius, min(clip.width, clip.height) / 2))
            }
            return CollageLayout(size: CGSize(width: width, height: height), cells: cells)
        }

        static func columns(_ settings: CollageSettings, count: Int) -> Int {
            min(max(1, settings.columns), max(1, count))
        }

        private static func canvasHeight(_ aspects: [CGFloat], settings s: CollageSettings, width: CGFloat,
                                         gap: CGFloat, margin: CGFloat) -> CGFloat {
            if let ratio = s.canvas.ratio { return (width / ratio).rounded() }
            let n = CGFloat(aspects.count)
            let inner = width - 2 * margin
            var height: CGFloat
            switch s.style {
            case .grid:
                let c = CGFloat(columns(s, count: aspects.count))
                let rows = ceil(n / c)
                let cellWidth = (inner - (c - 1) * gap) / c
                let mean = min(max(aspects.reduce(0, +) / n, 0.5), 2)
                height = 2 * margin + rows * (cellWidth / mean) + (rows - 1) * gap
            case .row:
                height = 2 * margin + (inner - (n - 1) * gap) / aspects.reduce(0, +)
            case .column:
                height = 2 * margin + aspects.reduce(0) { $0 + inner / $1 } + (n - 1) * gap
            case .featured:
                let a = aspects[0]
                height = width / (a > 1.15 ? 4.0 / 3.0 : (a < 0.87 ? 4.0 / 5.0 : 1))
            }
            let floor = max(64, 2 * margin + 16)
            return min(max(height, floor), width * 4, maxPixels / width).rounded()
        }

        private static func cellFrames(_ aspects: [CGFloat], settings s: CollageSettings, area: CGRect, gap: CGFloat) -> [CGRect] {
            let n = aspects.count
            switch s.style {
            case .grid:
                return grid(count: n, columns: columns(s, count: n), in: area, gap: gap)
            case .row:
                // A fitted canvas sizes each slot to its picture; a fixed one splits evenly.
                let weights = s.canvas == .auto ? aspects : Array(repeating: 1, count: n)
                return strip(weights: weights, in: area, gap: gap, horizontal: true)
            case .column:
                let weights = s.canvas == .auto ? aspects.map { 1 / $0 } : Array(repeating: 1, count: n)
                return strip(weights: weights, in: area, gap: gap, horizontal: false)
            case .featured:
                return featured(aspects, in: area, gap: gap)
            }
        }

        /// Equal cells, filled left to right. A short last row leaves its remaining slots empty.
        private static func grid(count n: Int, columns c: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
            let rows = (n + c - 1) / c
            let w = (area.width - CGFloat(c - 1) * gap) / CGFloat(c)
            let h = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            return (0..<n).map { i in
                let col = CGFloat(i % c), row = CGFloat(i / c)
                return snapped(CGRect(x: area.minX + col * (w + gap), y: area.minY + row * (h + gap), width: w, height: h))
            }
        }

        /// One row or column, each slot sized by its weight.
        private static func strip(weights: [CGFloat], in area: CGRect, gap: CGFloat, horizontal: Bool) -> [CGRect] {
            let n = CGFloat(weights.count)
            let total = weights.reduce(0, +)
            let length = (horizontal ? area.width : area.height) - (n - 1) * gap
            var cursor = horizontal ? area.minX : area.minY
            return weights.map { weight in
                let span = length * weight / total
                defer { cursor += span + gap }
                return snapped(horizontal
                    ? CGRect(x: cursor, y: area.minY, width: span, height: area.height)
                    : CGRect(x: area.minX, y: cursor, width: area.width, height: span))
            }
        }

        /// Rows that always fill the area (the last row's cells stretch), with a column
        /// count chosen so cells come closest to `target` (width over height).
        private static func packed(count n: Int, in area: CGRect, gap: CGFloat, target: CGFloat) -> [CGRect] {
            guard n > 0 else { return [] }
            var best = 1
            var bestScore = CGFloat.greatestFiniteMagnitude
            for c in 1...n {
                let rows = (n + c - 1) / c
                let w = (area.width - CGFloat(c - 1) * gap) / CGFloat(c)
                let h = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
                guard w > 1, h > 1 else { continue }
                let score = abs(log((w / h) / target)) + (n % c == 0 ? 0 : 0.12)
                if score < bestScore { bestScore = score; best = c }
            }
            let rows = (n + best - 1) / best
            let h = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            var frames: [CGRect] = []
            for row in 0..<rows {
                let count = row == rows - 1 ? n - best * (rows - 1) : best
                let w = (area.width - CGFloat(count - 1) * gap) / CGFloat(count)
                for col in 0..<count {
                    frames.append(snapped(CGRect(x: area.minX + CGFloat(col) * (w + gap),
                                                 y: area.minY + CGFloat(row) * (h + gap), width: w, height: h)))
                }
            }
            return frames
        }

        /// The first image large, the rest sharing the remaining side or bottom.
        private static func featured(_ aspects: [CGFloat], in area: CGRect, gap: CGFloat) -> [CGRect] {
            guard aspects.count > 1 else { return [snapped(area)] }
            let share: CGFloat = 0.62
            let rest = Array(aspects.dropFirst())
            let target = min(max(rest.reduce(0, +) / CGFloat(rest.count), 0.6), 1.7)
            if area.width >= area.height {
                let bigWidth = ((area.width - gap) * share).rounded()
                let big = CGRect(x: area.minX, y: area.minY, width: bigWidth, height: area.height)
                let side = CGRect(x: big.maxX + gap, y: area.minY, width: area.maxX - big.maxX - gap, height: area.height)
                return [snapped(big)] + packed(count: rest.count, in: side, gap: gap, target: target)
            } else {
                let bigHeight = ((area.height - gap) * share).rounded()
                let big = CGRect(x: area.minX, y: area.minY, width: area.width, height: bigHeight)
                let side = CGRect(x: area.minX, y: big.maxY + gap, width: area.width, height: area.maxY - big.maxY - gap)
                return [snapped(big)] + packed(count: rest.count, in: side, gap: gap, target: target)
            }
        }

        /// A rounded rect with Apple's continuous corners, the same shape the preview clips with.
        static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
            guard radius > 0.01 else { return CGPath(rect: rect, transform: nil) }
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        }

        /// Draws the collage. `image(i, longestSide)` supplies picture `i` at about the size it will be drawn,
        /// so memory stays low even with 20 big photos.
        static func render(_ layout: CollageLayout, settings: CollageSettings, space: CGColorSpace,
                           image: (Int, Int) throws -> CGImage, job: JobContext? = nil) throws -> CGImage {
            let w = Int(layout.size.width), h = Int(layout.size.height)
            guard let ctx = bitmap(width: w, height: h, space: space, opaque: settings.isOpaque) else {
                throw JobError.failed("This collage is too big to draw. Try a smaller width.")
            }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            if let background = settings.background {
                ctx.setFillColor(background.cg)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            for (i, cell) in layout.cells.enumerated() {
                try job?.checkCancelled()
                let longest = Int(ceil(max(cell.image.width, cell.image.height)))
                let picture = try image(i, max(16, longest))
                ctx.saveGState()
                ctx.addPath(roundedPath(cell.clip, radius: cell.radius))
                ctx.clip()
                Ink.drawImage(picture, in: cell.image, ctx: ctx)
                ctx.restoreGState()
                job?.progress(0.04 + 0.86 * Double(i + 1) / Double(max(1, layout.cells.count)))
            }
            guard let result = ctx.makeImage() else { throw JobError.failed("Couldn't draw the collage.") }
            return result
        }

        /// Loads each image at the size it's drawn, renders and writes `out` as "png" or "jpg".
        static func export(_ urls: [URL], aspects: [CGFloat], settings: CollageSettings, wideGamut: Bool,
                           format: String, to out: URL, job: JobContext) throws {
            job.progress(0.02)
            let layout = layout(aspects: aspects, settings: settings)
            let space = CGColorSpace(name: wideGamut ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
            let image = try render(layout, settings: settings, space: space, image: { i, longest in
                try MarkupKit.picture(urls[i], maxPixel: longest).image
            }, job: job)
            try job.checkCancelled()
            job.progress(0.93)
            try ImageEngine.write(ImageEngine.Loaded(image: image, properties: [:], pointsPerPixel: 1),
                                  as: format, to: out, quality: 0.92, keepMetadata: false)
            job.progress(1)
        }
    }
}

// MARK: - Controls

extension MarkupKit {
    /// Springs used across both windows: quick, a little soft, and gone when Reduce Motion is on.
    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86)
    }

    /// "Label ......... control", the row style both windows use.
    struct FormRow<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content

        var body: some View {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                content
            }
            .frame(height: 20)
        }
    }

    /// Grey squares that stand for "transparent".
    struct Checkerboard: View {
        var square: CGFloat = 4

        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.97)))
                let columns = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
                var path = Path()
                for row in 0..<rows {
                    for col in 0..<columns where (row + col) % 2 == 0 {
                        path.addRect(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square))
                    }
                }
                ctx.fill(path, with: .color(Color(white: 0.84)))
            }
        }
    }

    /// One round color chip. A ring in the accent marks the current choice.
    struct SwatchChip: View {
        let swatch: Swatch
        var selected: Bool
        var diameter: CGFloat = 18
        var action: () -> Void
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: action) {
                ZStack {
                    if let color = swatch.color {
                        Circle().fill(color.color)
                    } else {
                        Checkerboard(square: diameter / 4).clipShape(Circle())
                    }
                    Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
                }
                .frame(width: diameter, height: diameter)
                .padding(3)
                .overlay {
                    Circle()
                        .strokeBorder(ToolStyle.orange, lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                        .scaleEffect(selected ? 1 : 0.85)
                }
                .scaleEffect(hovering && !selected ? 1.08 : 1)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(MarkupKit.spring(reduceMotion), value: selected)
            .animation(MarkupKit.spring(reduceMotion), value: hovering)
            .help(swatch.name)
            .accessibilityLabel(swatch.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    /// The popover behind a color well: rows of five chips.
    struct SwatchGrid: View {
        let swatches: [Swatch]
        let selected: RGBA?
        let pick: (RGBA?) -> Void

        var body: some View {
            let rows = stride(from: 0, to: swatches.count, by: 5).map { Array(swatches[$0..<min($0 + 5, swatches.count)]) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(rows[r]) { swatch in
                            SwatchChip(swatch: swatch, selected: swatch.color == selected, diameter: 22) {
                                pick(swatch.color)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    /// The capsule color well from the original (a color pill in a soft grey ring).
    /// Clicking it opens the swatches.
    struct ColorWell: View {
        let color: RGBA
        let swatches: [Swatch]
        let onPick: (RGBA) -> Void
        @State private var open = false
        @State private var hovering = false

        var body: some View {
            Button {
                open.toggle()
            } label: {
                Capsule()
                    .fill(color.color)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
                    .padding(2.5)
                    .frame(width: 40, height: 20)
                    .background(Capsule().fill(Color.primary.opacity(hovering || open ? 0.13 : 0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SwatchGrid(swatches: swatches, selected: color) { picked in
                    if let picked { onPick(picked) }
                    open = false
                }
            }
            .help("Color")
            .accessibilityLabel("Color")
        }
    }

    /// A section header with a turning chevron, like a disclosure group but the whole row clicks.
    struct DisclosureHeader: View {
        let title: String
        let isOpen: Bool
        let toggle: () -> Void
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.85))
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(MarkupKit.spring(reduceMotion), value: isOpen)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        }
    }

    /// Small template glyphs for segmented size pickers: lines for strokes, dots for text and callouts.
    @MainActor
    enum SizeGlyph {
        private static var cache: [String: NSImage] = [:]

        static func image(lines: Bool, level: Int) -> NSImage {
            let key = "\(lines)-\(level)"
            if let cached = cache[key] { return cached }
            let image = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { rect in
                NSColor.black.setFill()
                if lines {
                    let thickness: CGFloat = [1.5, 3, 5][min(level, 2)]
                    NSBezierPath(roundedRect: NSRect(x: 1, y: rect.midY - thickness / 2, width: 14, height: thickness),
                                 xRadius: thickness / 2, yRadius: thickness / 2).fill()
                } else {
                    let d: CGFloat = [5, 7.5, 10.5][min(level, 2)]
                    NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
                }
                return true
            }
            image.isTemplate = true
            cache[key] = image
            return image
        }
    }
}
