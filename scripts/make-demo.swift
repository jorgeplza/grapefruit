// Renders the README demo: a HEIC dragged off the desktop, Shift tapped, the wheel
// blooming, JPG lit and dropped on. Uses the app's real petal geometry and hit test,
// and the timings from WheelController / WheelMotion.
//
// Usage:
//   swiftc -O -parse-as-library scripts/make-demo.swift Sources/Grapefruit/Wheel/WheelGeometry.swift -o /tmp/make-demo
//   /tmp/make-demo <frames-dir>
//   ffmpeg -framerate 30 -i <frames-dir>/f%04d.png -vf "scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" -loop 0 docs/demo.gif

import AppKit
import CoreImage

@main
struct Demo {
    static let W: CGFloat = 800, H: CGFloat = 500, S: CGFloat = 2
    static let fps = 30.0, duration = 5.0
    static let metrics = WheelMetrics()
    static let center = CGPoint(x: 400, y: 250)
    static let labels = ["JPG", "PNG", "WEBP", "TIFF", "AVIF", "BMP", "PDF"]  // a HEIC's petals, in order
    static let accent = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)   // default system accent
    static let ink = NSColor(white: 0, alpha: 0.85)
    static let iconSpot = CGPoint(x: 150, y: 318)   // the HEIC on the desktop
    static let newSpot = CGPoint(x: 150, y: 418)    // where the JPG appears

    // Times in seconds.
    static let tap = 0.75, open = 0.8, drop = 2.6
    static let squeezeAt = drop + 0.11

    static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "frames"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let (wall, blurred) = wallpapers()
        var tint = Tint(count: labels.count)
        let frames = Int(duration * fps)
        for f in 0..<frames {
            let t = Double(f) / fps
            let image = frame(t, wall: wall, blurred: blurred, tint: &tint)
            write(image, to: "\(out)/f\(String(format: "%04d", f)).png")
        }
        print("wrote \(frames) frames to \(out)")
    }

    // MARK: Timing

    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (Double) -> Double {
        { t in
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            var lo = 0.0, hi = 1.0, u = t
            for _ in 0..<40 {
                let x = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
                if x < t { lo = u } else { hi = u }
                u = (lo + hi) / 2
            }
            return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
        }
    }

    static let bloomCurve = bezier(0.18, 0.82, 0.24, 1)
    static let cutInCurve = bezier(0.2, 1.25, 0.4, 1)
    static let squeezeCurve = bezier(0.3, 0, 0.2, 1)
    static let easeInOut = bezier(0.42, 0, 0.58, 1)
    static let easeOut = bezier(0, 0, 0.58, 1)
    static let glide = bezier(0.45, 0, 0.2, 1)

    static func progress(_ t: Double, _ start: Double, _ length: Double, _ curve: (Double) -> Double) -> Double {
        curve(min(1, max(0, (t - start) / length)))
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p)) }

    /// The lit tint of each petal, eased over 0.16s like WheelMotion.tint.
    struct Tint {
        var from: [Double], to: [Double], since: [Double]
        init(count: Int) { from = Array(repeating: 0, count: count); to = from; since = from }
        func value(_ i: Int, _ t: Double) -> Double {
            from[i] + (to[i] - from[i]) * Demo.progress(t, since[i], 0.16, Demo.easeInOut)
        }
        mutating func set(_ i: Int, _ target: Double, _ t: Double) {
            guard to[i] != target else { return }
            from[i] = value(i, t); to[i] = target; since[i] = t
        }
    }

    static func cursor(_ t: Double) -> CGPoint {
        // Picked up near the icon's lower right, so the file hangs above-left of the arrow.
        let grab = CGPoint(x: iconSpot.x + 20, y: iconSpot.y + 18)
        // Aim just beside each label so the lit name stays readable.
        func beside(_ i: Int) -> CGPoint {
            let l = WheelGeometry.labelPoint(index: i, count: labels.count, center: center, metrics: metrics)
            return CGPoint(x: l.x + 21, y: l.y - 19)
        }
        let png = beside(1)
        let jpgDrop = beside(0)
        if t < 0.7 { return lerp(grab, center, progress(t, 0, 0.7, glide)) }
        if t < 1.25 { return center }
        if t < 1.65 { return lerp(center, png, progress(t, 1.25, 0.4, glide)) }
        if t < 1.95 { return png }
        if t < 2.35 { return lerp(png, jpgDrop, progress(t, 1.95, 0.4, glide)) }
        if t < 3.9 { return jpgDrop }
        return lerp(jpgDrop, grab, progress(t, 3.9, 0.6, glide))
    }

    // MARK: Frame

    static func frame(_ t: Double, wall: CGImage, blurred: CGImage, tint: inout Tint) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(W * S), height: Int(H * S), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        // y-down points, like SwiftUI.
        ctx.translateBy(x: 0, y: H * S)
        ctx.scaleBy(x: S, y: -S)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let full = CGRect(x: 0, y: 0, width: W, height: H)
        drawImage(ctx, wall, in: full)

        // Desktop files.
        desktopIcon(ctx, at: iconSpot, name: "IMG_2048.HEIC", alpha: 1, scale: 1)
        let born = progress(t, drop + 0.55, 0.32, bezier(0.2, 1.3, 0.4, 1))
        let gone = progress(t, 4.05, 0.35, easeInOut)
        if t > drop + 0.55 && gone < 1 {
            desktopIcon(ctx, at: newSpot, name: "IMG_2048.jpg", alpha: min(1, born * 1.4) * (1 - gone),
                        scale: lerp(0.7, 1, born))
        }

        // The wheel.
        let p = cursor(t)
        let isOpen = t >= open && t < drop
        let lit = isOpen ? WheelGeometry.petal(at: CGPoint(x: p.x - center.x, y: p.y - center.y),
                                               count: labels.count, metrics: metrics) : nil
        let popped = t >= drop ? 0 : nil
        for i in labels.indices {
            tint.set(i, (lit == i || popped == i) ? 1 : 0, t)
        }

        if t >= open && t < squeezeAt + 0.34 {
            let bloom = progress(t, open, 0.3, bloomCurve)
            var scale = lerp(0.45, 1, bloom)
            var alpha = bloom
            if t >= squeezeAt {
                let k = squeezeCurve(min(1, (t - squeezeAt) / 0.34))
                if k < 0.35 {
                    scale *= lerp(1, 0.95, k / 0.35); alpha *= Double(lerp(1, 0.62, k / 0.35))
                } else {
                    scale *= lerp(0.95, 0.86, (k - 0.35) / 0.65); alpha *= Double(lerp(0.62, 0, (k - 0.35) / 0.65))
                }
            }
            let turn = lerp(-28, 0, bloom) * .pi / 180
            wheel(ctx, t: t, scale: scale, turn: turn, alpha: alpha, lit: lit ?? popped, tint: tint, blurred: blurred)
        }

        // Shift tap, shown like a keystroke overlay.
        let keyIn = progress(t, tap, 0.15, easeOut)
        let keyOut = progress(t, 1.6, 0.25, easeInOut)
        if t >= tap && keyOut < 1 { keycap(ctx, alpha: keyIn * (1 - keyOut), scale: lerp(0.85, 1, keyIn)) }

        // Drag ghost and cursor.
        let ghostOut = progress(t, drop, 0.1, easeOut)
        let ghostIn = progress(t, 4.55, 0.3, easeOut)
        let ghost = t < drop ? 1 : (t > 4.55 ? ghostIn : 1 - ghostOut)
        if ghost > 0 {
            ctx.saveGState()
            ctx.setAlpha(0.66 * ghost)
            photo(ctx, CGRect(x: p.x - 46, y: p.y - 38, width: 52, height: 39), corner: 5)
            ctx.restoreGState()
            if t > 0.05 && t < drop { copyBadge(ctx, at: CGPoint(x: p.x + 15, y: p.y + 23), alpha: lit != nil ? 1 : 0) }
        }
        arrow(ctx, at: p)

        NSGraphicsContext.current = nil
        return ctx.makeImage()!
    }

    static func wheel(_ ctx: CGContext, t: Double, scale: CGFloat, turn: CGFloat, alpha: Double, lit: Int?,
                      tint: Tint, blurred: CGImage) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // Glass plate: the wallpaper behind it, blurred and brightened, with a light rim.
        let r = metrics.pith * scale
        let plate = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * S), blur: 34 * S, color: NSColor(white: 0, alpha: 0.22).cgColor)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)
        ctx.fillEllipse(in: plate)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: plate)
        ctx.clip()
        drawImage(ctx, blurred, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.34).cgColor)
        ctx.fill(plate)
        // Light catching the top edge.
        let sheen = CGGradient(colorsSpace: nil, colors: [NSColor(white: 1, alpha: 0.32).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: center.x, y: plate.minY), end: CGPoint(x: center.x, y: center.y), options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: plate.insetBy(dx: 0.6, dy: 0.6))

        // Petals, each cutting in from the core with its own delay.
        for i in labels.indices {
            let cut = progress(t, open + Double(i) * 0.016, 0.36, cutInCurve)
            let pScale = lerp(0.55, 1, cut) * scale
            let pTurn = turn + lerp(-16, 0, cut) * .pi / 180
            let k = tint.value(i, t)
            let pop = progress(t, drop, 0.16, easeOut) * (lit == i && t >= drop ? 16 : 0)
            let out = WheelGeometry.outward(index: i, count: labels.count, by: pop * scale)

            ctx.saveGState()
            ctx.setAlpha(CGFloat(min(1, max(0, (cut - 0.0) * 1.6))))
            ctx.translateBy(x: center.x + out.width, y: center.y + out.height)
            ctx.rotate(by: pTurn)
            ctx.scaleBy(x: pScale, y: pScale)
            ctx.translateBy(x: -center.x, y: -center.y)

            let path = WheelGeometry.petalPath(index: i, count: labels.count, center: center, metrics: metrics)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * S), blur: 6 * S, color: NSColor(white: 0, alpha: 0.07).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.46).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            if k > 0 {
                ctx.addPath(path)
                ctx.setFillColor(accent.withAlphaComponent(CGFloat(k)).cgColor)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.78 * (1 - CGFloat(k))).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()

            let color = NSColor(white: lerp(0, 1, k), alpha: lerp(0.85, 1, k))
            let at = WheelGeometry.labelPoint(index: i, count: labels.count, center: center, metrics: metrics)
            text(labels[i], NSFont.systemFont(ofSize: 15.5, weight: .semibold), color, centeredAt: at, tracking: 0.31)
            ctx.restoreGState()
        }

        // Core.
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: turn)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -center.x, y: -center.y)
        let hub = CGRect(x: center.x - metrics.hub, y: center.y - metrics.hub, width: metrics.hub * 2, height: metrics.hub * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * S), blur: 12 * S, color: NSColor(white: 0, alpha: 0.08).cgColor)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.76).cgColor)
        ctx.fillEllipse(in: hub)
        ctx.restoreGState()
        text("CONVERT", NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold), accent,
             centeredAt: CGPoint(x: center.x, y: center.y - 15), tracking: 1.08)
        if let lit {
            text(labels[lit], NSFont.systemFont(ofSize: 17, weight: .bold), accent, centeredAt: CGPoint(x: center.x, y: center.y + 7))
        } else {
            text("2.4 MB", NSFont.systemFont(ofSize: 13, weight: .medium), NSColor(white: 0, alpha: 0.5),
                 centeredAt: CGPoint(x: center.x, y: center.y + 7))
        }
        ctx.restoreGState()

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Pieces

    static func desktopIcon(_ ctx: CGContext, at c: CGPoint, name: String, alpha: Double, scale: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        let r = CGRect(x: c.x - 34, y: c.y - 25, width: 68, height: 51)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * S), blur: 6 * S, color: NSColor(white: 0, alpha: 0.3).cgColor)
        ctx.setFillColor(.white)
        ctx.fill(r.insetBy(dx: -2.5, dy: -2.5))
        ctx.restoreGState()
        photo(ctx, r, corner: 0)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * S), blur: 3 * S, color: NSColor(white: 0, alpha: 0.55).cgColor)
        text(name, NSFont.systemFont(ofSize: 11.5, weight: .medium), .white, centeredAt: CGPoint(x: c.x, y: c.y + 40))
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// A small sunset photo: sky, sun, two hills.
    static func photo(_ ctx: CGContext, _ r: CGRect, corner: CGFloat) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.clip()
        let sky = CGGradient(colorsSpace: nil, colors: [NSColor(srgbRed: 0.98, green: 0.62, blue: 0.42, alpha: 1).cgColor,
                                                        NSColor(srgbRed: 0.99, green: 0.84, blue: 0.62, alpha: 1).cgColor] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.96, blue: 0.85, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.56, y: r.minY + r.height * 0.3, width: r.width * 0.2, height: r.width * 0.2))
        ctx.setFillColor(NSColor(srgbRed: 0.42, green: 0.36, blue: 0.5, alpha: 1).cgColor)
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.62))
        ctx.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.7),
                         control: CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.42))
        ctx.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.58),
                         control: CGPoint(x: r.minX + r.width * 0.8, y: r.minY + r.height * 0.5))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func keycap(_ ctx: CGContext, alpha: Double, scale: CGFloat) {
        let c = CGPoint(x: 400, y: 456)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        let r = CGRect(x: c.x - 44, y: c.y - 17, width: 88, height: 34)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.62).cgColor)
        ctx.fillPath()
        text("⇧  Shift", NSFont.systemFont(ofSize: 14, weight: .semibold), .white, centeredAt: c)
        ctx.restoreGState()
    }

    /// The green + macOS shows when a drop will copy.
    static func copyBadge(_ ctx: CGContext, at c: CGPoint, alpha: Double) {
        guard alpha > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - 4, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 4, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 4)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 4))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func arrow(_ ctx: CGContext, at p: CGPoint) {
        let pts: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 17.5), .init(x: 4.2, y: 13.6), .init(x: 7.1, y: 20.3),
                              .init(x: 9.9, y: 19.1), .init(x: 7, y: 12.5), .init(x: 12.6, y: 12.5)]
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: p.x + $0.x * 1.1, y: p.y + $0.y * 1.1) })
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * S), blur: 3 * S, color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.6)
        ctx.setStrokeColor(.white)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(.black)
        ctx.fillPath()
    }

    static func text(_ s: String, _ font: NSFont, _ color: NSColor, centeredAt c: CGPoint, tracking: CGFloat = 0) {
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
        let size = str.size()
        str.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
    }

    /// Draws an image right side up in the y-down context.
    static func drawImage(_ ctx: CGContext, _ image: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // MARK: Wallpaper

    /// A soft dawn wallpaper, plus the heavily blurred copy the glass shows.
    static func wallpapers() -> (CGImage, CGImage) {
        let w = Int(W * S), h = Int(H * S)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let base = CGGradient(colorsSpace: nil, colors: [NSColor(srgbRed: 0.33, green: 0.52, blue: 0.74, alpha: 1).cgColor,
                                                         NSColor(srgbRed: 0.55, green: 0.66, blue: 0.82, alpha: 1).cgColor,
                                                         NSColor(srgbRed: 0.93, green: 0.70, blue: 0.58, alpha: 1).cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        // CG space is y-up here: the warm end sits at the bottom.
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w) * 0.3, y: 0), options: [.drawsAfterEndLocation])
        func blob(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
            let g = CGGradient(colorsSpace: nil, colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            let p = CGPoint(x: x * S, y: CGFloat(h) - y * S)
            ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r * S, options: [])
        }
        blob(620, 120, 320, NSColor(srgbRed: 0.98, green: 0.74, blue: 0.62, alpha: 0.75))
        blob(160, 90, 260, NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 0.8))
        blob(420, 470, 300, NSColor(srgbRed: 0.97, green: 0.62, blue: 0.55, alpha: 0.55))
        blob(760, 430, 240, NSColor(srgbRed: 0.5, green: 0.6, blue: 0.85, alpha: 0.6))
        let sharp = ctx.makeImage()!

        let ci = CIContext()
        func blur(_ image: CGImage, _ radius: CGFloat) -> CGImage {
            let input = CIImage(cgImage: image).clampedToExtent()
            let output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * S])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            return ci.createCGImage(output, from: output.extent)!
        }
        let soft = blur(sharp, 20)
        return (soft, blur(soft, 26))
    }

    static func write(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
