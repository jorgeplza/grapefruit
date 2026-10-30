import AppKit
import SwiftUI

/// Crop Image: an orange crop box over the photo, aspect presets and exact pixel sizes, like the original.
/// Several images get the same crop, centered on each one.
struct CropImageTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: CropModel
    /// The box when the current drag began. Non-nil while dragging.
    @State private var dragStart: CGRect?
    @State private var showGuides = false
    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var focus: SizeField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "crop-canvas"

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _model = StateObject(wrappedValue: CropModel(urls: session.urls))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                canvas
                    .frame(height: 408)
                if model.isBatch {
                    Text("Same crop for all \(session.urls.count) images, centered on each.")
                        .font(ToolStyle.label)
                        .foregroundStyle(ToolStyle.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }
                controls
                    .padding(.top, model.isBatch ? 8 : 14)
            }
        } footer: {
            ToolFooter(resetEnabled: model.canReset, onReset: reset,
                       primaryTitle: "Apply", primaryEnabled: model.canApply, onPrimary: apply)
        }
        .onAppear(perform: syncFields)
        .onChange(of: model.outputSize) { old, new in follow(old, new) }
        .onChange(of: focus) { old, _ in
            if let old { commit(old) }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size)
            let fit = PhotoToolKit.Fit(pixels: model.pixelSize, in: area.insetBy(dx: 6, dy: 6))
            let box = fit.view(model.crop)
            ZStack(alignment: .topLeading) {
                if model.failed {
                    PhotoToolKit.LoadFailure(name: model.displayName, dark: false)
                        .frame(width: area.width, height: area.height)
                } else {
                    photo(fit: fit)
                    if !model.isBatch { drawLayer(fit: fit) }
                    PhotoToolKit.Outside(outer: fit.rect, hole: box)
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    if showGuides {
                        PhotoToolKit.Thirds(box: box)
                            .stroke(Color.white.opacity(0.7), lineWidth: 0.75)
                            .shadow(color: .black.opacity(0.35), radius: 0.5)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    PhotoToolKit.BoxFrame(rect: box, line: 1.5, space: Self.space, movable: !model.isBatch,
                                          onResize: { knob, t, phase in resize(knob, by: t, phase, fit: fit) },
                                          onMove: { t, phase in move(by: t, phase, fit: fit) })
                    if showGuides {
                        PhotoToolKit.GlassPill {
                            Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                                .monospacedDigit()
                        }
                        .frame(width: area.width)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: area.width, height: area.height)
            .coordinateSpace(.named(Self.space))
        }
    }

    private func photo(fit: PhotoToolKit.Fit) -> some View {
        ZStack {
            if let image = model.preview {
                if model.info?.hasAlpha == true { PhotoToolKit.Checkerboard() }
                Image(decorative: image, scale: 1)
                    .resizable()
                    // Tiny images show crisp pixels instead of a blur.
                    .interpolation(fit.rect.width / CGFloat(max(image.width, 1)) > 3 ? .none : .high)
                    .transition(.opacity)
            } else {
                PhotoToolKit.LoadingTile(dark: false, corner: 2)
            }
        }
        .frame(width: fit.rect.width, height: fit.rect.height)
        .position(x: fit.rect.midX, y: fit.rect.midY)
        .animation(.easeOut(duration: 0.18), value: model.preview != nil)
        .allowsHitTesting(false)
    }

    /// Dragging on the photo outside the box draws a new box.
    private func drawLayer(fit: PhotoToolKit.Fit) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: fit.rect.width, height: fit.rect.height)
            .position(x: fit.rect.midX, y: fit.rect.midY)
            .pointerStyle(.rectSelection)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged { draw(from: $0.startLocation, to: $0.location, fit: fit, ended: false) }
                    .onEnded { draw(from: $0.startLocation, to: $0.location, fit: fit, ended: true) }
            )
    }

    // MARK: Gestures

    /// Starts a drag the first time a gesture reports, and drops any half-typed size.
    private func beginDrag() -> CGRect {
        if let dragStart { return dragStart }
        let start = model.crop
        dragStart = start
        focus = nil
        syncFields()
        withAnimation(.easeOut(duration: 0.15)) { showGuides = true }
        return start
    }

    private func endDrag() {
        dragStart = nil
        withAnimation(.easeOut(duration: 0.2)) { showGuides = false }
    }

    private func resize(_ knob: PhotoToolKit.Knob, by t: CGSize, _ phase: PhotoToolKit.BoxFrame.Phase, fit: PhotoToolKit.Fit) {
        guard model.canEdit else { return }
        let start = beginDrag()
        let flags = NSEvent.modifierFlags
        // Shift keeps the current shape in Free; Option grows from the middle. Batches always grow from the middle.
        let aspect = model.aspect.ratio ?? (flags.contains(.shift) ? start.width / max(start.height, 1) : nil)
        let centered = model.isBatch || flags.contains(.option)
        let next = PhotoToolKit.resize(start, knob: knob, by: fit.pixels(t), in: model.bounds,
                                       minSize: 18 / fit.scale, aspect: aspect, centered: centered)
        model.setCrop(next, keepExact: false)
        if phase == .ended { endDrag() }
    }

    private func move(by t: CGSize, _ phase: PhotoToolKit.BoxFrame.Phase, fit: PhotoToolKit.Fit) {
        guard model.canEdit, !model.isBatch else { return }
        let start = beginDrag()
        model.setCrop(PhotoToolKit.move(start, by: fit.pixels(t), in: model.bounds), keepExact: true)
        if phase == .ended { endDrag() }
    }

    private func draw(from a: CGPoint, to b: CGPoint, fit: PhotoToolKit.Fit, ended: Bool) {
        guard model.canEdit, !model.isBatch else { return }
        _ = beginDrag()
        let rect = PhotoToolKit.drawnRect(from: fit.pixel(a), to: fit.pixel(b), aspect: model.aspect.ratio,
                                          in: model.bounds, minSize: 18 / fit.scale)
        model.setCrop(rect, keepExact: false)
        if ended { endDrag() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Text("Aspect ratio")
                    .font(ToolStyle.label)
                Spacer(minLength: 8)
                Picker("Aspect ratio", selection: aspectBinding) {
                    ForEach(CropAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 252)
            }
            .frame(height: 30)

            HStack(spacing: 7) {
                Text("W")
                    .font(ToolStyle.label)
                sizeField(.width, text: $widthText)
                Text("H")
                    .font(ToolStyle.label)
                    .padding(.leading, 5)
                sizeField(.height, text: $heightText)
                Text("px")
                    .font(ToolStyle.label)
                    .foregroundStyle(ToolStyle.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        }
        .disabled(!model.canEdit)
        .onChange(of: widthText) { _, text in typed(.width, text) }
        .onChange(of: heightText) { _, text in typed(.height, text) }
    }

    private var aspectBinding: Binding<CropAspect> {
        Binding(get: { model.aspect }, set: { aspect in
            focus = nil
            withAnimation(PhotoToolKit.motion(reduceMotion)) { model.setAspect(aspect) }
            syncFields()
        })
    }

    private func sizeField(_ field: SizeField, text: Binding<String>) -> some View {
        let focused = focus == field
        return TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5).monospacedDigit())
            .padding(.horizontal, 7)
            .frame(width: 64, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? ToolStyle.orange.opacity(0.75) : Color.primary.opacity(0.13),
                                  lineWidth: focused ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: focused)
            .focusEffectDisabled()
            .focused($focus, equals: field)
            .onSubmit { commit(field) }
            .accessibilityLabel(field == .width ? "Width in pixels" : "Height in pixels")
    }

    // MARK: Size fields

    private static func text(_ value: CGFloat) -> String { "\(Int(value.rounded()))" }

    private func syncFields() {
        let size = model.outputSize
        widthText = Self.text(size.width)
        heightText = Self.text(size.height)
    }

    /// Keeps the fields on the box while it changes, without touching a size that's being typed.
    private func follow(_ old: CGSize, _ new: CGSize) {
        if focus != .width || widthText == Self.text(old.width) { widthText = Self.text(new.width) }
        if focus != .height || heightText == Self.text(old.height) { heightText = Self.text(new.height) }
    }

    /// Digits only. With a fixed ratio the other side follows as you type.
    private func typed(_ field: SizeField, _ text: String) {
        let digits = String(text.filter { ("0"..."9").contains($0) }.prefix(5))
        if digits != text {
            if field == .width { widthText = digits } else { heightText = digits }
            return
        }
        // Only real typing moves the other side; syncing the fields must not round-trip a pixel.
        let current = field == .width ? model.outputSize.width : model.outputSize.height
        guard focus == field, digits != Self.text(current),
              let ratio = model.aspect.ratio, let n = Double(digits), n > 0 else { return }
        if field == .width {
            heightText = Self.text(max(1, CGFloat(n) / ratio))
        } else {
            widthText = Self.text(max(1, CGFloat(n) * ratio))
        }
    }

    private func commit(_ field: SizeField) {
        guard let w = Double(widthText), let h = Double(heightText), w >= 1, h >= 1 else {
            syncFields()
            return
        }
        let size = CGSize(width: w, height: h)
        if size != model.outputSize {
            withAnimation(PhotoToolKit.motion(reduceMotion)) { model.setOutputSize(size) }
        }
        syncFields()
    }

    // MARK: Footer

    private func reset() {
        focus = nil
        withAnimation(PhotoToolKit.motion(reduceMotion)) { model.reset() }
        syncFields()
    }

    private func apply() {
        // A size typed without pressing Return still counts.
        if let field = focus { commit(field) }
        guard model.canApply else { return }
        let plan = model.plan
        session.runEach(ext: { PhotoToolKit.outputExtension(for: $0) }) { src, out, ctx in
            try PhotoToolKit.CropPlan.export(src, plan: plan, format: PhotoToolKit.outputFormat(for: src), to: out, ctx: ctx)
        }
    }
}

private enum SizeField: Hashable { case width, height }

private enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, wide, tall, classic, classicTall

    var id: Self { self }

    var title: String {
        switch self {
        case .free: "Free"
        case .square: "1:1"
        case .wide: "16:9"
        case .tall: "9:16"
        case .classic: "4:3"
        case .classicTall: "3:4"
        }
    }

    /// Width over height, or nil when the box can take any shape.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .wide: 16 / 9
        case .tall: 9 / 16
        case .classic: 4 / 3
        case .classicTall: 3 / 4
        }
    }
}

// MARK: - Model

@MainActor
private final class CropModel: ObservableObject {
    /// Biggest side a typed size can ask for.
    static let maxSide: CGFloat = 16384

    let urls: [URL]
    /// The image on screen: the first one that opens.
    let info: PhotoToolKit.SourceInfo?
    @Published private(set) var preview: CGImage?
    @Published private(set) var failed: Bool
    /// Upright pixels of the image on screen, top-left origin.
    @Published private(set) var crop: CGRect
    @Published private(set) var aspect: CropAspect = .free
    /// A typed output size that the box alone can't give (bigger than the photo, or a batch).
    @Published private(set) var exact: CGSize?

    init(urls: [URL]) {
        self.urls = urls
        let info = urls.lazy.compactMap { PhotoToolKit.sourceInfo($0) }.first
        self.info = info
        failed = info == nil
        crop = info?.bounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let info else { return }
        PhotoToolKit.loadProxy(info.url, maxSide: 1400) { [weak self] image in
            guard let self else { return }
            if let image { self.preview = image } else { self.failed = true }
        }
    }

    var isBatch: Bool { urls.count > 1 }
    var canEdit: Bool { info != nil && !failed }
    var displayName: String { (info?.url ?? urls.first)?.lastPathComponent ?? "" }
    var pixelSize: CGSize { info?.pixelSize ?? CGSize(width: 3, height: 2) }
    var bounds: CGRect { CGRect(origin: .zero, size: pixelSize) }

    /// What the saved file measures.
    var outputSize: CGSize {
        exact ?? PhotoToolKit.pixelRect(crop, in: pixelSize).size
    }

    private var isWhole: Bool { PhotoToolKit.pixelRect(crop, in: pixelSize) == bounds }

    var canApply: Bool {
        guard canEdit else { return false }
        // In a batch a ratio matters even when the first image already has it.
        return !isWhole || exact != nil || (isBatch && aspect != .free)
    }

    var canReset: Bool { canEdit && (!isWhole || exact != nil || aspect != .free) }

    var plan: PhotoToolKit.CropPlan {
        PhotoToolKit.CropPlan(crop: crop, reference: pixelSize, exact: exact, batch: isBatch)
    }

    func setCrop(_ rect: CGRect, keepExact: Bool) {
        crop = rect
        if !keepExact { exact = nil }
    }

    func setAspect(_ next: CropAspect) {
        aspect = next
        guard let ratio = next.ratio else { return }
        exact = nil
        let center = isBatch ? nil : CGPoint(x: crop.midX, y: crop.midY)
        crop = PhotoToolKit.largest(aspect: ratio, in: bounds, around: center)
    }

    /// A typed size. If the photo has room, the box takes exactly that size; otherwise the box takes
    /// the biggest area of that shape and the result is scaled to the size.
    func setOutputSize(_ size: CGSize) {
        let target = CGSize(width: min(max(1, size.width.rounded()), Self.maxSide),
                            height: min(max(1, size.height.rounded()), Self.maxSide))
        if isBatch {
            exact = target
            crop = PhotoToolKit.CropPlan(crop: crop, reference: pixelSize, exact: target, batch: true)
                .region(for: pixelSize).rect
            return
        }
        let center = CGPoint(x: crop.midX, y: crop.midY)
        if target.width <= pixelSize.width, target.height <= pixelSize.height {
            exact = nil
            crop = PhotoToolKit.move(CGRect(x: center.x - target.width / 2, y: center.y - target.height / 2,
                                            width: target.width, height: target.height), by: .zero, in: bounds)
        } else {
            exact = target
            crop = PhotoToolKit.largest(aspect: target.width / target.height, in: bounds, around: center)
        }
    }

    func reset() {
        aspect = .free
        exact = nil
        crop = bounds
    }
}

// MARK: - Engine

extension PhotoToolKit {
    /// Everything the job needs to crop one or many files.
    struct CropPlan: Sendable {
        /// The box on the first image, in its upright pixels.
        var crop: CGRect
        var reference: CGSize
        var exact: CGSize?
        var batch: Bool

        /// The pixels to keep in an image of `size`, and the size to scale them to (nil keeps them as they are).
        func region(for size: CGSize) -> (rect: CGRect, output: CGSize?) {
            let bounds = CGRect(origin: .zero, size: size)
            if !batch {
                // Same file; map proportionally in case the decoder disagrees with the header by a pixel.
                let sx = size.width / max(reference.width, 1), sy = size.height / max(reference.height, 1)
                let r = PhotoToolKit.pixelRect(CGRect(x: crop.minX * sx, y: crop.minY * sy,
                                                      width: crop.width * sx, height: crop.height * sy), in: size)
                if let exact, exact != r.size { return (r, exact) }
                return (r, nil)
            }
            if let exact {
                if exact.width <= size.width, exact.height <= size.height {
                    return (PhotoToolKit.pixelRect(centered(exact, in: size), in: size), nil)
                }
                let r = PhotoToolKit.pixelRect(PhotoToolKit.largest(aspect: exact.width / exact.height, in: bounds), in: size)
                return (r, exact)
            }
            // Same shape and the same share of the image, centered.
            let aspect = crop.width / max(crop.height, 1)
            let reach = PhotoToolKit.largest(aspect: aspect, in: CGRect(origin: .zero, size: reference))
            let share = min(1, crop.width / max(reach.width, 1))
            let biggest = PhotoToolKit.largest(aspect: aspect, in: bounds)
            let target = CGSize(width: biggest.width * share, height: biggest.height * share)
            return (PhotoToolKit.pixelRect(centered(target, in: size), in: size), nil)
        }

        private func centered(_ s: CGSize, in size: CGSize) -> CGRect {
            CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height)
        }

        /// Full resolution, same format, metadata kept (sizes updated).
        static func export(_ src: URL, plan: CropPlan, format: String, to out: URL, ctx: JobContext) throws {
            ctx.progress(0.05)
            let loaded = try ImageEngine.load(src)
            try ctx.checkCancelled()
            ctx.progress(0.45)
            let size = CGSize(width: loaded.image.width, height: loaded.image.height)
            let (rect, output) = plan.region(for: size)
            guard var image = loaded.image.cropping(to: rect) else {
                throw JobError.failed("Couldn't crop this image.")
            }
            if let output { image = PhotoToolKit.scaled(image, to: output) }
            try ctx.checkCancelled()
            ctx.progress(0.7)
            try PhotoToolKit.save(image, metadata: loaded.properties, format: format, to: out, ctx: ctx)
            ctx.progress(1)
        }
    }
}
