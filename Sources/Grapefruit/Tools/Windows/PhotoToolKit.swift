import AppKit
import CoreImage
import ImageIO
import Metal
import SwiftUI

/// Shared pieces for the four photo tools (Edit Photo, Crop Image, Add BG, Redact Photo):
/// quick previews, one Core Image context, output writing, and the orange box editor.
/// Everything lives in this namespace so nothing collides with the other tool windows.
enum PhotoToolKit {

    // MARK: - Look

    /// Measured from the original's windows.
    enum Look {
        /// The dark well behind the photo in Edit Photo and Redact Photo.
        static let darkWell = Color(white: 0.08)
        static let wellCorner: CGFloat = 12
        /// Crop and redaction boxes: orange outline, square corner knobs, capsule edge knobs.
        static let knob: CGFloat = 9
        static let knobCorner: CGFloat = 2.5
        static let edgeKnob = CGSize(width: 18, height: 4.5)
        /// Settings rows under the preview.
        static let rowHeight: CGFloat = 28
    }

    /// Quick and interruptible. With Reduce Motion it becomes a short ease with no overshoot.
    static func motion(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.25, bounce: 0.12)
    }

    // MARK: - Reading the source

    /// What the window needs before any pixels load: read from the file header in a millisecond.
    struct SourceInfo: Sendable {
        let url: URL
        let format: String
        /// Upright size: EXIF rotation already applied.
        let pixelSize: CGSize
        let hasAlpha: Bool

        var longEdge: CGFloat { max(pixelSize.width, pixelSize.height) }
        var shortEdge: CGFloat { min(pixelSize.width, pixelSize.height) }
        var bounds: CGRect { CGRect(origin: .zero, size: pixelSize) }
    }

    static func sourceInfo(_ url: URL) -> SourceInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let turned = (5...8).contains(orientation)
        return SourceInfo(url: url,
                          format: Catalog.format(of: url) ?? url.pathExtension.lowercased(),
                          pixelSize: turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height),
                          hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false)
    }

    /// An upright copy at most `maxSide` pixels long. ImageIO decodes at reduced size, so 50 MP stays quick.
    static func proxy(_ url: URL, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Loads a proxy off the main thread and hands it back on the main thread.
    static func loadProxy(_ url: URL, maxSide: Int, _ done: @escaping @MainActor (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = proxy(url, maxSide: maxSide)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(image) }
            }
        }
    }

    // MARK: - Background rendering

    /// Runs only the newest request. While one render runs, later ones replace each other,
    /// so dragging a slider never queues up stale frames.
    final class LatestOnly: @unchecked Sendable {
        private let queue: DispatchQueue
        private let lock = NSLock()
        private var pending: (() -> Void)?
        private var running = false

        init(_ label: String) {
            queue = DispatchQueue(label: "grapefruit.photo.\(label)", qos: .userInitiated)
        }

        func submit(_ work: @escaping () -> Void) {
            let start: Bool = lock.withLock {
                pending = work
                if running { return false }
                running = true
                return true
            }
            if start { queue.async { self.drain() } }
        }

        private func drain() {
            while true {
                let next: (() -> Void)? = lock.withLock {
                    let work = pending
                    pending = nil
                    if work == nil { running = false }
                    return work
                }
                guard let next else { return }
                autoreleasepool { next() }
            }
        }
    }

    /// One Metal-backed Core Image context for every preview and export. Core Image contexts are thread safe.
    static let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "Grapefruit photo tools"]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The picture's own RGB space (Display P3 stays P3), else sRGB.
    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return sRGB
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Renders a Core Image recipe into pixels. 16 bits per channel when `deep`.
    static func makeImage(_ image: CIImage, extent: CGRect, space: CGColorSpace, deep: Bool = false) -> CGImage? {
        let format: CIFormat = deep ? .RGBA16 : .RGBA8
        if let out = ciContext.createCGImage(image, from: extent, format: format, colorSpace: space) { return out }
        // Some embedded profiles can't be rendered into; sRGB always can.
        return ciContext.createCGImage(image, from: extent, format: format, colorSpace: sRGB)
    }

    /// The same picture without an alpha channel, for photos that never had one. Keeps depth and colours.
    static func droppingAlpha(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        let deep = image.bitsPerComponent > 8
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: rgbSpace(of: image),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// High quality resample to an exact size.
    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        guard w != image.width || h != image.height else { return image }
        let alpha = hasAlpha(image)
        let deep = image.bitsPerComponent > 8
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                  space: rgbSpace(of: image),
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                    : CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: - Saving

    /// The format a photo tool saves: the source's own, or PNG when this Mac can't write it (WebP without an encoder).
    static func outputFormat(for url: URL) -> String {
        let format = Catalog.format(of: url) ?? "png"
        switch format {
        case "jpg", "png", "heic", "tiff": return format
        case "webp": return Capabilities.hasWebPEncoder ? "webp" : "png"
        default: return ImageEngine.utTypes[format] != nil ? format : "png"
        }
    }

    /// Extension for the output: the original spelling when the format is unchanged ("JPEG" stays "JPEG").
    static func outputExtension(for url: URL) -> String {
        let format = outputFormat(for: url)
        let ext = url.pathExtension
        return Catalog.format(of: url) == format && !ext.isEmpty ? ext : format
    }

    /// Saves pixels with the source's metadata, updated for the new size.
    /// `stripLocation` drops GPS and place names (redacted copies).
    static func save(_ image: CGImage, metadata: [CFString: Any], format: String, to url: URL,
                     stripLocation: Bool = false, ctx: JobContext? = nil) throws {
        var props = metadata
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        props[kCGImagePropertyHasAlpha] = nil
        props[kCGImagePropertyDepth] = nil
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        if stripLocation { props = withoutLocation(props) }
        let loaded = ImageEngine.Loaded(image: image, properties: props, pointsPerPixel: 1)
        try ImageEngine.write(loaded, as: format, to: url, ctx: ctx)
    }

    static func withoutLocation(_ metadata: [CFString: Any]) -> [CFString: Any] {
        var props = metadata
        props[kCGImagePropertyGPSDictionary] = nil
        if var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
                        kCGImagePropertyIPTCExtLocationCreated, kCGImagePropertyIPTCExtLocationShown] {
                iptc[key] = nil
            }
            props[kCGImagePropertyIPTCDictionary] = iptc
        }
        return props
    }

    // MARK: - Colour

    /// An sRGB colour that can cross threads and be stored in settings.
    struct RGBA: Equatable, Hashable, Sendable {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

        init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(hex: UInt32) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
        }

        init(_ color: Color) {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            r = ns.redComponent; g = ns.greenComponent; b = ns.blueComponent; a = ns.alphaComponent
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: sRGB) ?? CIColor(red: r, green: g, blue: b, alpha: a) }
        func with(alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    }

    // MARK: - Geometry

    /// Where a picture sits when fitted into a box, and how to map between view points and pixels.
    struct Fit: Equatable {
        var rect: CGRect
        /// View points per image pixel.
        var scale: CGFloat

        init(pixels: CGSize, in box: CGRect) {
            guard pixels.width > 0, pixels.height > 0, box.width > 0, box.height > 0 else {
                rect = box
                scale = 1
                return
            }
            let s = min(box.width / pixels.width, box.height / pixels.height)
            let w = pixels.width * s, h = pixels.height * s
            rect = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
            scale = s
        }

        func view(_ r: CGRect) -> CGRect {
            CGRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale,
                   width: r.width * scale, height: r.height * scale)
        }

        func pixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - rect.minX) / scale, y: (p.y - rect.minY) / scale)
        }

        func pixels(_ s: CGSize) -> CGSize {
            CGSize(width: s.width / scale, height: s.height / scale)
        }
    }

    /// The eight knobs of a box, clockwise from the top left.
    enum Knob: CaseIterable, Hashable {
        case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading

        var isCorner: Bool { [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading].contains(self) }
        var movesMinX: Bool { [.topLeading, .leading, .bottomLeading].contains(self) }
        var movesMaxX: Bool { [.topTrailing, .trailing, .bottomTrailing].contains(self) }
        var movesMinY: Bool { [.topLeading, .top, .topTrailing].contains(self) }
        var movesMaxY: Bool { [.bottomLeading, .bottom, .bottomTrailing].contains(self) }

        var resizePosition: FrameResizePosition {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .trailing: .trailing
            case .bottomTrailing: .bottomTrailing
            case .bottom: .bottom
            case .bottomLeading: .bottomLeading
            case .leading: .leading
            }
        }

        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: movesMinX ? r.minX : (movesMaxX ? r.maxX : r.midX),
                    y: movesMinY ? r.minY : (movesMaxY ? r.maxY : r.midY))
        }
    }

    /// Drags one knob of `start` by `d` (pixels). Keeps `aspect` (width / height) when given, grows from the
    /// middle when `centered`, and never leaves `bounds` or gets smaller than `minSize`.
    static func resize(_ start: CGRect, knob: Knob, by d: CGSize, in bounds: CGRect, minSize: CGFloat,
                       aspect: CGFloat? = nil, centered: Bool = false) -> CGRect {
        let minSize = max(0, min(minSize, bounds.width, bounds.height))
        if let a = aspect, a > 0 {
            return resizeKeepingAspect(start, knob: knob, by: d, in: bounds, minSize: minSize, aspect: a, centered: centered)
        }
        if centered {
            let cx = start.midX, cy = start.midY
            var hw = start.width / 2, hh = start.height / 2
            if knob.movesMinX { hw -= d.width } else if knob.movesMaxX { hw += d.width }
            if knob.movesMinY { hh -= d.height } else if knob.movesMaxY { hh += d.height }
            hw = min(max(hw, minSize / 2), cx - bounds.minX, bounds.maxX - cx)
            hh = min(max(hh, minSize / 2), cy - bounds.minY, bounds.maxY - cy)
            return CGRect(x: cx - hw, y: cy - hh, width: hw * 2, height: hh * 2)
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if knob.movesMinX { minX = min(max(start.minX + d.width, bounds.minX), maxX - minSize) }
        if knob.movesMaxX { maxX = max(min(start.maxX + d.width, bounds.maxX), minX + minSize) }
        if knob.movesMinY { minY = min(max(start.minY + d.height, bounds.minY), maxY - minSize) }
        if knob.movesMaxY { maxY = max(min(start.maxY + d.height, bounds.maxY), minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func resizeKeepingAspect(_ start: CGRect, knob: Knob, by d: CGSize, in bounds: CGRect,
                                            minSize: CGFloat, aspect a: CGFloat, centered: Bool) -> CGRect {
        let minWidth = max(minSize, minSize * a)
        let k: CGFloat = centered ? 2 : 1
        if knob.isCorner {
            // The opposite corner (or the middle) stays put; the box follows whichever axis the pointer pulls more.
            let ax = centered ? start.midX : (knob.movesMinX ? start.maxX : start.minX)
            let ay = centered ? start.midY : (knob.movesMinY ? start.maxY : start.minY)
            let proposedW = start.width + (knob.movesMinX ? -d.width : d.width) * k
            let proposedH = start.height + (knob.movesMinY ? -d.height : d.height) * k
            var w = max(proposedW, proposedH * a)
            let roomX = centered ? 2 * min(ax - bounds.minX, bounds.maxX - ax)
                                 : (knob.movesMinX ? ax - bounds.minX : bounds.maxX - ax)
            let roomY = centered ? 2 * min(ay - bounds.minY, bounds.maxY - ay)
                                 : (knob.movesMinY ? ay - bounds.minY : bounds.maxY - ay)
            let maxW = min(roomX, roomY * a)
            w = min(max(w, min(minWidth, maxW)), maxW)
            let h = w / a
            let x = centered ? ax - w / 2 : (knob.movesMinX ? ax - w : ax)
            let y = centered ? ay - h / 2 : (knob.movesMinY ? ay - h : ay)
            return CGRect(x: x, y: y, width: w, height: h)
        }
        if knob.movesMinX || knob.movesMaxX {
            // A side knob sets the width; the height follows around the middle.
            let ax = centered ? start.midX : (knob.movesMinX ? start.maxX : start.minX)
            var w = start.width + (knob.movesMinX ? -d.width : d.width) * k
            let roomX = centered ? 2 * min(ax - bounds.minX, bounds.maxX - ax)
                                 : (knob.movesMinX ? ax - bounds.minX : bounds.maxX - ax)
            let maxW = min(roomX, bounds.height * a)
            w = min(max(w, min(minWidth, maxW)), maxW)
            let h = w / a
            let x = centered ? ax - w / 2 : (knob.movesMinX ? ax - w : ax)
            let y = min(max(start.midY - h / 2, bounds.minY), bounds.maxY - h)
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let ay = centered ? start.midY : (knob.movesMinY ? start.maxY : start.minY)
        var h = start.height + (knob.movesMinY ? -d.height : d.height) * k
        let roomY = centered ? 2 * min(ay - bounds.minY, bounds.maxY - ay)
                             : (knob.movesMinY ? ay - bounds.minY : bounds.maxY - ay)
        let maxH = min(roomY, bounds.width / a)
        h = min(max(h, min(minWidth / a, maxH)), maxH)
        let w = h * a
        let y = centered ? ay - h / 2 : (knob.movesMinY ? ay - h : ay)
        let x = min(max(start.midX - w / 2, bounds.minX), bounds.maxX - w)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Moves a box without letting it leave `bounds`.
    static func move(_ start: CGRect, by d: CGSize, in bounds: CGRect) -> CGRect {
        var r = start.offsetBy(dx: d.width, dy: d.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// The biggest box of `aspect` that fits `bounds`, centered on `center` and nudged inside.
    static func largest(aspect a: CGFloat, in bounds: CGRect, around center: CGPoint? = nil) -> CGRect {
        guard a > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var w = bounds.width, h = w / a
        if h > bounds.height { h = bounds.height; w = h * a }
        let c = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        var r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - w)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - h)
        return r
    }

    /// A box dragged out from `p0` towards `p1`, kept inside `bounds` (and to `aspect` when set).
    static func drawnRect(from p0: CGPoint, to p1: CGPoint, aspect: CGFloat?, in bounds: CGRect, minSize: CGFloat) -> CGRect {
        let start = CGPoint(x: min(max(p0.x, bounds.minX), bounds.maxX), y: min(max(p0.y, bounds.minY), bounds.maxY))
        let minSize = max(1, min(minSize, bounds.width, bounds.height))
        var sx: CGFloat = p1.x < start.x ? -1 : 1
        var sy: CGFloat = p1.y < start.y ? -1 : 1
        // Starting right at an edge, grow inwards instead of collapsing.
        if (sx > 0 ? bounds.maxX - start.x : start.x - bounds.minX) < minSize { sx = -sx }
        if (sy > 0 ? bounds.maxY - start.y : start.y - bounds.minY) < minSize { sy = -sy }
        let roomX = sx > 0 ? bounds.maxX - start.x : start.x - bounds.minX
        let roomY = sy > 0 ? bounds.maxY - start.y : start.y - bounds.minY
        var w = max(abs(p1.x - start.x), minSize)
        var h = max(abs(p1.y - start.y), minSize)
        if let a = aspect, a > 0 {
            w = min(max(w, h * a), roomX, roomY * a)
            h = w / a
        } else {
            w = min(w, roomX)
            h = min(h, roomY)
        }
        return CGRect(x: sx > 0 ? start.x : start.x - w, y: sy > 0 ? start.y : start.y - h, width: w, height: h)
    }

    /// Whole-pixel version of a box, kept inside the picture. Size is rounded on its own so a typed
    /// 500 px never turns into 501 px.
    static func pixelRect(_ r: CGRect, in size: CGSize) -> CGRect {
        let w = min(max(1, r.width.rounded()), size.width)
        let h = min(max(1, r.height.rounded()), size.height)
        let x = min(max(0, r.minX.rounded()), size.width - w)
        let y = min(max(0, r.minY.rounded()), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Views

    /// The orange box: outline, square corner knobs and capsule edge knobs, with generous hit areas
    /// and resize pointers. Reports drags (in the named coordinate space) and leaves the maths to the tool.
    struct BoxFrame: View {
        enum Phase { case changed, ended }

        var rect: CGRect
        var line: CGFloat = 2
        var space: String
        var movable = true
        var onResize: (Knob, CGSize, Phase) -> Void
        var onMove: (CGSize, Phase) -> Void = { _, _ in }

        @State private var grabbing = false

        var body: some View {
            ZStack(alignment: .topLeading) {
                if movable {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .pointerStyle(grabbing ? .grabActive : .grabIdle)
                        .gesture(drag(minimum: 1) { t, phase in
                            grabbing = phase == .changed
                            onMove(t, phase)
                        })
                }
                Rectangle()
                    .stroke(ToolStyle.orange, lineWidth: line)
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                ForEach(Knob.allCases, id: \.self) { knob in
                    knobShape(knob)
                        .position(knob.point(in: rect))
                        .allowsHitTesting(false)
                }
                ForEach(Knob.allCases, id: \.self) { knob in
                    let size = hitSize(knob)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: size.width, height: size.height)
                        .position(knob.point(in: rect))
                        .pointerStyle(.frameResize(position: knob.resizePosition))
                        .gesture(drag(minimum: 0) { t, phase in onResize(knob, t, phase) })
                }
            }
        }

        @ViewBuilder private func knobShape(_ knob: Knob) -> some View {
            if knob.isCorner {
                RoundedRectangle(cornerRadius: Look.knobCorner, style: .continuous)
                    .fill(ToolStyle.orange)
                    .frame(width: Look.knob, height: Look.knob)
            } else {
                let horizontal = knob == .top || knob == .bottom
                let length = horizontal ? rect.width : rect.height
                Capsule()
                    .fill(ToolStyle.orange)
                    .frame(width: horizontal ? Look.edgeKnob.width : Look.edgeKnob.height,
                           height: horizontal ? Look.edgeKnob.height : Look.edgeKnob.width)
                    .opacity(length > 44 ? 1 : 0)
            }
        }

        private func hitSize(_ knob: Knob) -> CGSize {
            let corner: CGFloat = 20, edge: CGFloat = 12
            switch knob {
            case .top, .bottom: return CGSize(width: max(0, rect.width - corner), height: edge)
            case .leading, .trailing: return CGSize(width: edge, height: max(0, rect.height - corner))
            default: return CGSize(width: corner, height: corner)
            }
        }

        private func drag(minimum: CGFloat, _ report: @escaping (CGSize, Phase) -> Void) -> some Gesture {
            DragGesture(minimumDistance: minimum, coordinateSpace: .named(space))
                .onChanged { report($0.translation, .changed) }
                .onEnded { report($0.translation, .ended) }
        }
    }

    /// Everything inside `outer` except `hole`. Animates with the hole (crop dimming).
    struct Outside: Shape {
        var outer: CGRect
        var hole: CGRect

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
            get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
            set {
                hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                              width: newValue.second.first, height: newValue.second.second)
            }
        }

        func path(in rect: CGRect) -> Path {
            var p = Path(outer)
            p.addRect(hole)
            return p
        }
    }

    /// Rule-of-thirds lines inside a box.
    struct Thirds: Shape {
        var box: CGRect

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
            get { AnimatablePair(AnimatablePair(box.minX, box.minY), AnimatablePair(box.width, box.height)) }
            set {
                box = CGRect(x: newValue.first.first, y: newValue.first.second,
                             width: newValue.second.first, height: newValue.second.second)
            }
        }

        func path(in rect: CGRect) -> Path {
            var p = Path()
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3
                let y = box.minY + box.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
            }
            return p
        }
    }

    /// Shows through transparent pixels.
    struct Checkerboard: View {
        var dark = false
        var cell: CGFloat = 7

        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: dark ? 0.16 : 0.97)))
                var squares = Path()
                let cols = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
                for row in 0..<max(rows, 0) {
                    for col in 0..<max(cols, 0) where (row + col) % 2 == 1 {
                        squares.addRect(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                    }
                }
                ctx.fill(squares, with: .color(Color(white: dark ? 0.23 : 0.88)))
            }
            .allowsHitTesting(false)
        }
    }

    /// Grey stand-in while a preview loads. A spinner shows only if loading takes a moment.
    struct LoadingTile: View {
        var dark: Bool
        var corner: CGFloat = 3
        @State private var showSpinner = false
        @State private var pulse = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(dark ? Color.white.opacity(pulse ? 0.085 : 0.05) : Color.black.opacity(pulse ? 0.075 : 0.045))
                .overlay {
                    if showSpinner {
                        ProgressView()
                            .controlSize(.small)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .transition(.opacity)
                    }
                }
                .task {
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                    }
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeOut(duration: 0.15)) { showSpinner = true }
                }
                .allowsHitTesting(false)
        }
    }

    /// Short inline error in place of the preview.
    struct LoadFailure: View {
        var name: String
        var dark: Bool

        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 17))
                Text("Couldn't open this image")
                    .font(.system(size: 12, weight: .medium))
                Text(name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240)
            }
            .foregroundStyle(dark ? Color.white.opacity(0.62) : ToolStyle.secondary)
            .multilineTextAlignment(.center)
        }
    }

    /// A settings row: label on the left, controls on the right.
    struct Row<Content: View>: View {
        var title: String
        var secondaryLabel = true
        var height: CGFloat = Look.rowHeight
        @ViewBuilder var content: Content

        var body: some View {
            HStack(spacing: 10) {
                Text(title)
                    .font(ToolStyle.label)
                    .foregroundStyle(secondaryLabel ? ToolStyle.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                content
            }
            .frame(height: height)
        }
    }

    /// Small dark glass capsule for messages and controls that sit on top of a photo.
    struct GlassPill<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            content
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .glassEffect(.regular.tint(Color.black.opacity(0.35)), in: Capsule())
                .environment(\.colorScheme, .dark)
        }
    }

    /// The colour capsule from the original: the colour in a soft grey ring. Opens the colour panel.
    struct ColorWell: View {
        var color: RGBA
        var selected = false
        var action: () -> Void
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: action) {
                Capsule()
                    .fill(color.color)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
                    .frame(width: 36, height: 16)
                    .padding(4)
                    .background(Capsule().fill(Color.primary.opacity(hovering && isEnabled ? 0.13 : 0.09)))
                    .overlay {
                        if selected {
                            Capsule()
                                .strokeBorder(ToolStyle.orange, lineWidth: 2)
                                .transition(.scale(scale: 1.18).combined(with: .opacity))
                        }
                    }
                    .opacity(isEnabled ? 1 : 0.4)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityLabel("Color")
        }
    }

    /// The one listener for the shared colour panel. It lives for the whole app, so the panel never
    /// points at an object that's gone, and only the window that opened it last gets the colours.
    @MainActor
    final class ColorPanelLink: NSObject {
        static let shared = ColorPanelLink()
        private var onChange: ((RGBA) -> Void)?
        private var owner: ObjectIdentifier?

        func open(with color: RGBA, owner: AnyObject, onChange: @escaping (RGBA) -> Void) {
            let panel = NSColorPanel.shared
            self.onChange = nil
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
            self.owner = ObjectIdentifier(owner)
            self.onChange = onChange
            panel.setTarget(self)
            panel.setAction(#selector(changed(_:)))
            panel.orderFront(nil)
        }

        /// Stops listening and closes the panel, if `owner` was the last to open it.
        func release(owner: AnyObject) {
            guard self.owner == ObjectIdentifier(owner) else { return }
            onChange = nil
            self.owner = nil
            NSColorPanel.shared.orderOut(nil)
        }

        @objc private func changed(_ sender: NSColorPanel) {
            guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
            onChange?(RGBA(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent))
        }
    }

    /// Hands back the window hosting a SwiftUI view (for sheets and key handling).
    struct WindowReader: NSViewRepresentable {
        var onChange: (NSWindow?) -> Void

        func makeNSView(context: Context) -> Probe {
            let view = Probe()
            view.onChange = onChange
            return view
        }

        func updateNSView(_ nsView: Probe, context: Context) {
            nsView.onChange = onChange
        }

        final class Probe: NSView {
            var onChange: ((NSWindow?) -> Void)?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                onChange?(window)
            }
        }
    }
}
