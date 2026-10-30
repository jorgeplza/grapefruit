// Draws the app icon (Slice: the wheel with its
// top segment lit, inside a rind ring) and writes an .icns.
// Usage: swift scripts/make-icon.swift Support/AppIcon.icns
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// MARK: Geometry (same petal as Sources/Grapefruit/Wheel/WheelGeometry.swift, y-down)

func angle(_ i: Int, _ n: Int) -> CGFloat { (n == 3 ? .pi : .pi / 2) - 2 * .pi * CGFloat(i) / CGFloat(n) }
func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: cos(a) * r, y: -sin(a) * r) }

func addArc(_ path: CGMutablePath, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat) {
    let total = a1 - a0
    let segments = max(1, Int(ceil(abs(total) / (.pi / 4))))
    let step = total / CGFloat(segments)
    var start = a0
    for _ in 0..<segments {
        let end = start + step
        let k = 4.0 / 3.0 * tan(step / 4)
        let p0 = point(r, start), p3 = point(r, end)
        path.addCurve(to: p3,
                      control1: CGPoint(x: p0.x - k * r * sin(start), y: p0.y - k * r * cos(start)),
                      control2: CGPoint(x: p3.x + k * r * sin(end), y: p3.y + k * r * cos(end)))
        start = end
    }
}

func petal(_ i: Int, _ n: Int, inner: CGFloat, outer: CGFloat, gap: CGFloat, corner: CGFloat) -> CGPath {
    let a = angle(i, n), span = 2 * .pi / CGFloat(n)
    let l = a - span / 2, s = a + span / 2
    func half(_ r: CGFloat) -> CGFloat { asin(min(0.95, gap / 2 / max(r, gap / 2 + 0.01))) }
    let d = l + half(outer), e = s - half(outer)
    let ci = l + half(inner), g = s - half(inner)
    let f = min(0.15, (e - d) * 0.24), u = min(0.18, (g - ci) * 0.18)
    let v = inner / max(0.01, cos(u)), y = v + inner * tan(u), o = outer - corner
    let path = CGMutablePath()
    path.move(to: point(y, l + half(y)))
    path.addLine(to: point(o, l + half(o)))
    path.addQuadCurve(to: point(outer, d + f), control: point(outer, d))
    addArc(path, outer, from: d + f, to: e - f)
    path.addQuadCurve(to: point(o, s - half(o)), control: point(outer, e))
    path.addLine(to: point(y, s - half(y)))
    path.addQuadCurve(to: point(inner, g - u), control: point(v, s - half(v)))
    addArc(path, inner, from: g - u, to: ci + u)
    path.addQuadCurve(to: point(y, l + half(y)), control: point(v, l + half(v)))
    path.closeSubpath()
    return path
}

/// macOS icon shape: a superellipse close to Apple's continuous-corner square.
func squircle(_ c: CGFloat, _ size: CGFloat, _ n: CGFloat = 5) -> CGPath {
    let a = size / 2, path = CGMutablePath()
    for k in 0...240 {
        let t = CGFloat(k) / 240 * 2 * .pi, co = cos(t), si = sin(t)
        let p = CGPoint(x: c + a * (co < 0 ? -1 : 1) * pow(abs(co), 2 / n),
                        y: c + a * (si < 0 ? -1 : 1) * pow(abs(si), 2 / n))
        k == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

// MARK: Paint

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Top-to-bottom gradient across the path's bounds (SVG's default linearGradient).
func fillLinear(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient) {
    let b = path.boundingBoxOfPath
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
    ctx.restoreGState()
}

/// Radial gradient in the path's bounding box units (SVG objectBoundingBox), so it stretches with the shape.
func fillRadial(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, cx: CGFloat, cy: CGFloat, r: CGFloat) {
    let b = path.boundingBoxOfPath
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.translateBy(x: b.minX, y: b.minY)
    ctx.scaleBy(x: b.width, y: b.height)
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func fill(_ ctx: CGContext, _ path: CGPath, _ c: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(c)
    ctx.fillPath()
}

func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil) }

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Design space: 1024 units, y-down, like the SVG.
func design(_ size: Int) -> CGAffineTransform {
    let k = CGFloat(size) / 1024
    return CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: 0, ty: CGFloat(size))
}

/// One foreground layer, drawn on its own so it can get the Liquid Glass stand-in.
func layer(_ size: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext(size)
    ctx.concatenate(design(size))
    ctx.translateBy(x: 512, y: 512)
    body(ctx)
    return ctx.makeImage()!
}

/// The gallery's glass filter: a lit top edge, a 7-unit band blurred and kept inside the shape.
func rimLight(_ img: CGImage, _ size: Int) -> CGImage {
    let k = CGFloat(size) / 1024
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let alpha = CIImage(cgImage: img)
    let lower = alpha.transformed(by: CGAffineTransform(translationX: 0, y: -7 * k))
    let band = alpha.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: lower])
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.75)).cropped(to: rect)
        .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: band])
        .applyingGaussianBlur(sigma: 2.2 * k)
        .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha])
        .cropped(to: rect)
    let ci = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    return ci.createCGImage(white, from: rect)!
}

func draw(size: Int) -> CGImage {
    let k = CGFloat(size) / 1024
    let px = CGRect(x: 0, y: 0, width: size, height: size)
    let ctx = makeContext(size)
    let toDesign = design(size)
    let shape = squircle(512, 824)

    // Base, with a soft drop shadow. Shadows live in pixel space, so they scale by hand.
    ctx.saveGState()
    ctx.concatenate(toDesign)
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 32 * k, color: color(0x2a140c, 0.26))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fillLinear(ctx, shape, gradient([(0, color(0xfff8f0)), (1, color(0xf2e2d3))]))
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Rind ring, then the wheel: six pale segments, the top one lit and lifted, a core over the middle.
    let rind = layer(size) { c in
        fillLinear(c, circle(318), gradient([(0, color(0xfbc9a0)), (1, color(0xef9e6e))]))
        fill(c, circle(292), color(0xfff6ee))
    }
    let wheel = layer(size) { c in
        let flesh = gradient([(0, color(0xffe8df)), (1, color(0xf6b09f))])
        for i in 1..<7 {
            fillRadial(c, petal(i, 7, inner: 62, outer: 268, gap: 16, corner: 44), flesh, cx: 0.5, cy: 0.5, r: 0.62)
        }
        c.saveGState()
        c.translateBy(x: 0, y: -10)
        fillRadial(c, petal(0, 7, inner: 62, outer: 268, gap: 16, corner: 44),
                   gradient([(0, color(0xf28c84)), (1, color(0xd6555a))]), cx: 0.5, cy: 0.7, r: 0.7)
        c.restoreGState()
        fill(c, circle(48), color(0xfff6ee))
    }

    ctx.saveGState()
    ctx.concatenate(toDesign)
    ctx.addPath(shape)
    ctx.clip()
    ctx.concatenate(toDesign.inverted())
    for img in [rind, wheel] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 32 * k, color: color(0x8a3a22, 0.24))
        ctx.draw(img, in: px)
        ctx.restoreGState()
        ctx.draw(rimLight(img, size), in: px)
    }

    // Lit rim on the base: bright at the top, faint at the bottom.
    ctx.concatenate(toDesign)
    ctx.addPath(shape)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xffffff, 0.7)), (0.22, color(0xffffff, 0)),
                                     (0.88, color(0xffffff, 0)), (1, color(0xffffff, 0.2))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    let url = iconset.appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, draw(size: px), nil)
    CGImageDestinationFinalize(dest)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "icon: \(output)" : "iconutil failed")
