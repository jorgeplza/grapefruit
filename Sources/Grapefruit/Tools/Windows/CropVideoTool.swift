import SwiftUI

private typealias Kit = VideoToolKit

/// Crop Video: drag the crop or pick an aspect ratio, type an exact size, and save "name Cropped.ext"
/// with the original sound.
struct CropVideoTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var player: Kit.Player
    @State private var link = Kit.WindowLink()
    /// The kept part, in fractions of the picture as shown (0...1).
    @State private var crop = Self.full
    @State private var ratio = Ratio.free
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let canvasHeight: CGFloat

    private static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Room around the picture so the handles at its edges stay whole.
    private static let canvasInset: CGFloat = 9

    enum Ratio: String, CaseIterable, Identifiable {
        case free = "Free"
        case square = "1:1"
        case wide = "16:9"
        case tall = "9:16"
        case standard = "4:3"
        case standardTall = "3:4"

        var id: String { rawValue }

        var value: CGFloat? {
            switch self {
            case .free: nil
            case .square: 1
            case .wide: 16 / 9
            case .tall: 9 / 16
            case .standard: 4 / 3
            case .standardTall: 3 / 4
            }
        }
    }

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _player = State(initialValue: Kit.Player(url: session.url))
        canvasHeight = Kit.previewHeight(410, rest: 245, anchor: session.anchor)
    }

    // MARK: Geometry

    /// The picture's size in pixels, as shown.
    private var frameSize: CGSize { player.displaySize }

    private func pixels(_ r: CGRect) -> CGRect {
        let s = frameSize
        return CGRect(x: r.minX * s.width, y: r.minY * s.height, width: r.width * s.width, height: r.height * s.height)
    }

    private func fractions(_ r: CGRect, of s: CGSize) -> CGRect {
        guard s.width > 0, s.height > 0 else { return Self.full }
        let x = min(max(0, r.minX / s.width), 1)
        let y = min(max(0, r.minY / s.height), 1)
        return CGRect(x: x, y: y, width: min(r.width / s.width, 1 - x), height: min(r.height / s.height, 1 - y))
    }

    /// What gets saved: even sizes, inside the picture.
    private var pixelRect: CGRect { Kit.evenRect(pixels(crop), in: frameSize) }

    private var isFull: Bool {
        pixelRect == Kit.evenRect(CGRect(origin: .zero, size: frameSize), in: frameSize)
    }

    // MARK: Views

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                canvas
                HStack {
                    Text("Aspect ratio")
                        .font(Kit.Look.label)
                    Spacer()
                    Picker("Aspect ratio", selection: $ratio) {
                        ForEach(Ratio.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                .padding(.horizontal, Kit.Look.inset)
                .padding(.top, 12)
                sizeRow
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 10)
                Slider(value: scrub, in: 0...max(player.duration, 0.01))
                    .labelsHidden()
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 12)
                // No arrow-key shortcuts here: the arrows belong to the size fields.
                Kit.Transport(player: player, showsPlay: false, shortcuts: false)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 4)
            }
            .disabled(!player.isReady)
        } footer: {
            ToolFooter(resetEnabled: player.isReady && (!isFull || ratio != .free), onReset: reset,
                       primaryTitle: "Apply", primaryEnabled: player.isReady && !isFull, onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) { player.stop() })
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: ratio) { _, new in applyRatio(new) }
    }

    /// The picture, fitted, with the orange crop on top and everything outside it dimmed.
    private var canvas: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: Self.canvasInset, dy: Self.canvasInset)
            let video = Kit.fitted(player.displaySize, in: bounds)
            let rect = CGRect(x: video.minX + crop.minX * video.width, y: video.minY + crop.minY * video.height,
                              width: crop.width * video.width, height: crop.height * video.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Kit.Look.previewFill)
                    .frame(width: video.width, height: video.height)
                    .position(x: video.midX, y: video.midY)
                    .opacity(player.isReady ? 0 : 1)
                Kit.PlayerSurface(player: player.player)
                    .frame(width: video.width, height: video.height)
                    .position(x: video.midX, y: video.midY)
                    .opacity(player.isReady ? 1 : 0)
                    .animation(.easeOut(duration: 0.18), value: player.isReady)
                Kit.PreviewStatus(player: player, onDark: true)
                    .frame(width: video.width, height: video.height)
                    .position(x: video.midX, y: video.midY)
                if player.isReady {
                    Kit.DimOutside(outer: video, hole: rect)
                        .fill(Kit.Look.dim, style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    Kit.RectEditor(rect: rect, bounds: video, aspect: ratio.value,
                                   minSize: CGSize(width: 20, height: 20), space: "crop") { r in
                        crop = fractions(CGRect(x: r.minX - video.minX, y: r.minY - video.minY,
                                                width: r.width, height: r.height), of: video.size)
                    }
                    .modifier(Kit.OwnsDrags(link: link))
                }
            }
            .coordinateSpace(.named("crop"))
        }
        .frame(height: canvasHeight)
    }

    /// "W [1920] H [1080] px": type an exact size; the crop keeps its center.
    private var sizeRow: some View {
        HStack(spacing: 6) {
            Text("W")
                .font(Kit.Look.caption)
            TextField("Width", value: sizeBinding(\.width), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Text("H")
                .font(Kit.Look.caption)
                .padding(.leading, 6)
            TextField("Height", value: sizeBinding(\.height), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Text("px")
                .font(Kit.Look.caption)
                .foregroundStyle(ToolStyle.secondary)
            Spacer()
        }
        .monospacedDigit()
    }

    private var scrub: Binding<Double> {
        Binding(get: { player.time }, set: { player.seek(to: $0) })
    }

    private func sizeBinding(_ side: KeyPath<CGSize, CGFloat>) -> Binding<Int> {
        Binding(
            get: { Int(pixelRect.size[keyPath: side]) },
            set: { value in
                let typed = CGFloat(max(2, value))
                resize(width: side == \CGSize.width ? typed : nil, height: side == \CGSize.height ? typed : nil)
            }
        )
    }

    // MARK: Actions

    /// Sets the crop to a typed size around its center, keeping the ratio when one is chosen.
    private func resize(width: CGFloat?, height: CGFloat?) {
        let s = frameSize
        let current = pixels(crop)
        var w = width ?? current.width
        var h = height ?? current.height
        if let a = ratio.value {
            if width != nil { h = w / a } else { w = h * a }
            let fit = min(1, s.width / w, s.height / h)
            w *= fit
            h *= fit
        } else {
            w = min(w, s.width)
            h = min(h, s.height)
        }
        let x = min(max(0, current.midX - w / 2), s.width - w)
        let y = min(max(0, current.midY - h / 2), s.height - h)
        withAnimation(Kit.Look.motion(reduceMotion)) {
            crop = fractions(CGRect(x: x, y: y, width: w, height: h), of: s)
        }
    }

    /// The biggest crop of the new shape around the current crop's center.
    private func applyRatio(_ new: Ratio) {
        guard let a = new.value else { return }
        let s = frameSize
        let current = pixels(crop)
        let rect = Kit.largest(aspect: a, in: CGRect(origin: .zero, size: s),
                               around: CGPoint(x: current.midX, y: current.midY))
        withAnimation(Kit.Look.motion(reduceMotion)) {
            crop = fractions(rect, of: s)
        }
    }

    private func reset() {
        withAnimation(Kit.Look.motion(reduceMotion)) {
            ratio = .free
            crop = Self.full
        }
    }

    private func apply() {
        let rect = pixelRect
        player.stop()
        session.runEach { src, out, ctx in
            try VideoToolKit.crop(src, to: rect, output: out, ctx: ctx)
        }
    }
}
