import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Still images: decode with ImageIO (or AppKit for SVG), encode with ImageIO or cwebp.
enum ImageEngine {
    struct Loaded {
        var image: CGImage
        /// Source metadata (EXIF, GPS, IPTC...) with orientation already applied to the pixels.
        var properties: [CFString: Any]
        /// Points per pixel for PDF pages, from the file's DPI.
        var pointsPerPixel: CGFloat
    }

    static let utTypes: [String: UTType] = [
        "jpg": .jpeg, "png": .png, "heic": .heic, "tiff": .tiff, "bmp": .bmp,
        "avif": UTType("public.avif") ?? .heic, "gif": .gif,
    ]

    // MARK: Decoding

    static func load(_ url: URL, format: String? = nil, minimumSide: CGFloat = 0) throws -> Loaded {
        let f = format ?? Catalog.format(of: url) ?? url.pathExtension.lowercased()
        if f == "svg" { return try loadSVG(url, minimumSide: max(minimumSide, 1600)) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw JobError.failed("Couldn't read this image.")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1

        var image: CGImage?
        if orientation != 1 {
            // Bake the rotation into the pixels so every format shows it upright.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if image == nil {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let cg = image else { throw JobError.failed("Couldn't decode this image.") }

        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let ppp = dpi > 1 ? CGFloat(72 / dpi) : 1
        return Loaded(image: cg, properties: props, pointsPerPixel: ppp)
    }

    /// SVGs have no pixels; draw them big enough to stay sharp.
    private static func loadSVG(_ url: URL, minimumSide: CGFloat) throws -> Loaded {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
            throw JobError.failed("Couldn't read this SVG.")
        }
        let longest = max(svg.size.width, svg.size.height)
        let scale = max(1, minimumSide / longest)
        let w = Int((svg.size.width * scale).rounded())
        let h = Int((svg.size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw JobError.failed("Couldn't draw this SVG.")
        }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw JobError.failed("Couldn't draw this SVG.") }
        return Loaded(image: image, properties: [:], pointsPerPixel: 1 / scale)
    }

    // MARK: Encoding

    /// Writes `image` as `format` ("jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf").
    static func write(_ loaded: Loaded, as format: String, to url: URL, quality: Double? = nil,
                      keepMetadata: Bool = true, ctx: JobContext? = nil) throws {
        switch format {
        case "pdf":
            try writePDF([loaded], to: url)
        case "webp":
            try writeWebP(loaded.image, to: url, quality: quality ?? 0.9,
                          metadata: keepMetadata ? loaded.properties : nil, ctx: ctx)
        default:
            guard let type = utTypes[format] else { throw JobError.failed("Can't write \(format.uppercased()) images.") }
            var image = loaded.image
            if format == "jpg" || format == "bmp" { image = flattened(image) }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw JobError.failed("Can't write \(format.uppercased()) on this Mac.")
            }
            var props: [CFString: Any] = keepMetadata ? loaded.properties : [:]
            if !keepMetadata, let profile = loaded.properties[kCGImagePropertyProfileName] {
                props[kCGImagePropertyProfileName] = profile
            }
            switch format {
            case "jpg": props[kCGImageDestinationLossyCompressionQuality] = quality ?? 0.92
            case "heic": props[kCGImageDestinationLossyCompressionQuality] = quality ?? 0.85
            case "avif": props[kCGImageDestinationLossyCompressionQuality] = quality ?? 0.8
            case "tiff":
                var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = 5   // LZW
                props[kCGImagePropertyTIFFDictionary] = tiff
            default: break
            }
            if format == "png" || format == "bmp" {
                props[kCGImagePropertyGPSDictionary] = keepMetadata ? props[kCGImagePropertyGPSDictionary] : nil
            }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw JobError.failed("Couldn't save the \(format.uppercased()) file.")
            }
        }
    }

    /// cwebp copies metadata from its input, so the stand-in PNG carries the photo's EXIF, GPS and XMP
    /// when they're kept. Without `metadata` only the color profile goes across.
    static func writeWebP(_ image: CGImage, to url: URL, quality: Double, metadata: [CFString: Any]? = nil,
                          ctx: JobContext?) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".grapefruit-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw JobError.failed("Couldn't prepare the WebP file.")
        }
        CGImageDestinationAddImage(dest, image, metadata.map { $0 as CFDictionary })
        guard CGImageDestinationFinalize(dest) else { throw JobError.failed("Couldn't prepare the WebP file.") }
        let q = String(Int((quality * 100).rounded()))
        if let cwebp = Binaries.cwebp {
            try Shell.run(cwebp, ["-quiet", "-mt", "-q", q, "-alpha_q", "100", "-metadata", metadata == nil ? "icc" : "all",
                                  temp.path, "-o", url.path], ctx: ctx)
        } else {
            let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
            try Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", temp.path,
                                   "-c:v", "libwebp", "-quality", q, url.path], ctx: ctx)
        }
    }

    /// One PDF with one page per image, each page the image's own size.
    static func writePDF(_ images: [Loaded], to url: URL, fitTo pageSize: CGSize? = nil) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw JobError.failed("Couldn't create the PDF.")
        }
        for loaded in images {
            let w = CGFloat(loaded.image.width) * loaded.pointsPerPixel
            let h = CGFloat(loaded.image.height) * loaded.pointsPerPixel
            var box: CGRect
            var drawRect: CGRect
            if let page = pageSize {
                let landscape = w > h
                let size = landscape ? CGSize(width: max(page.width, page.height), height: min(page.width, page.height)) : page
                box = CGRect(origin: .zero, size: size)
                let margin: CGFloat = 0
                let scale = min((size.width - margin * 2) / w, (size.height - margin * 2) / h)
                let dw = w * scale, dh = h * scale
                drawRect = CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2, width: dw, height: dh)
            } else {
                box = CGRect(x: 0, y: 0, width: w, height: h)
                drawRect = box
            }
            pdf.beginPage(mediaBox: &box)
            pdf.interpolationQuality = .high
            pdf.draw(loaded.image, in: drawRect)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    /// JPEG and BMP can't hold transparency: put the picture on white.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Scale so the longest side is at most `maxSide` pixels.
    static func resized(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide, maxSide > 0 else { return image }
        let scale = Double(maxSide) / Double(longest)
        return resized(image, width: Int((Double(image.width) * scale).rounded()),
                       height: Int((Double(image.height) * scale).rounded()))
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info: UInt32
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: info = CGImageAlphaInfo.noneSkipLast.rawValue
        default: info = CGImageAlphaInfo.premultipliedLast.rawValue
        }
        guard let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    // MARK: Conversion

    static func convert(_ src: URL, format: String, to target: String, ctx: JobContext) throws -> [URL] {
        ctx.progress(0.1)
        let loaded = try load(src, format: format)
        try ctx.checkCancelled()
        ctx.progress(0.5)
        let out = ctx.output(Output.name(src, ext: Catalog.fileExtension(for: target)))
        try write(loaded, as: target, to: out, ctx: ctx)
        ctx.progress(1)
        return [out]
    }
}
