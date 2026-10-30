import AppKit
import CoreImage
import SwiftUI
import Vision

/// Redact Photo: drag boxes over anything private, or find faces and text on this Mac,
/// then cover them with a solid color or a blur that can't be undone. The copy drops location data.
struct RedactPhotoTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: RedactModel
    /// The box when the current drag began.
    @State private var dragStart: CGRect?
    /// The box being drawn right now.
    @State private var drawingID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "redact-canvas"

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _model = StateObject(wrappedValue: RedactModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                canvas
                    .frame(height: 520)
                if session.urls.count > 1 {
                    Text("Same boxes on all \(session.urls.count) images.")
                        .font(ToolStyle.label)
                        .foregroundStyle(ToolStyle.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }
                settings
                    .padding(.top, session.urls.count > 1 ? 4 : 10)
            }
            .background(PhotoToolKit.WindowReader { window in
                DispatchQueue.main.async { model.attachKeys(to: window) }
            })
        } footer: {
            ToolFooter(resetEnabled: model.canReset, onReset: reset,
                       primaryTitle: session.urls.count > 1 ? "Save Redacted Copies" : "Save Redacted Copy",
                       primaryEnabled: model.canSave, onPrimary: save)
        }
        .onDisappear {
            model.detachKeys()
            PhotoToolKit.ColorPanelLink.shared.release(owner: model)
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size)
            let fit = PhotoToolKit.Fit(pixels: model.pixelSize, in: area)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    PhotoToolKit.Look.darkWell
                        .contentShape(Rectangle())
                        .onTapGesture { deselect() }
                    if model.failed {
                        PhotoToolKit.LoadFailure(name: session.url.lastPathComponent, dark: true)
                            .frame(width: area.width, height: area.height)
                    } else {
                        photo(fit: fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: PhotoToolKit.Look.wellCorner, style: .continuous))

                // Boxes sit outside the clip so knobs at the photo's edge stay whole.
                if model.canEdit {
                    drawLayer(fit: fit)
                    ForEach(model.boxes) { box in
                        BoxView(box: box, rect: fit.view(box.rect), solid: model.style == .solid,
                                color: model.color, reduceMotion: reduceMotion)
                            .gesture(boxDrag(box, fit: fit))
                            .transition(.opacity)
                    }
                    if let box = model.selectedBox {
                        PhotoToolKit.BoxFrame(rect: fit.view(box.rect), line: 2, space: Self.space,
                                              onResize: { knob, t, phase in resize(box.id, knob, by: t, phase, fit: fit) },
                                              onMove: { t, phase in move(box.id, by: t, phase, fit: fit) })
                            .id(box.id)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: area.width, height: area.height)
            .coordinateSpace(.named(Self.space))
            .overlay(alignment: .bottom) {
                Group {
                    if let message = model.message {
                        PhotoToolKit.GlassPill { Text(message) }
                            .id(message)
                    } else if model.boxes.isEmpty, model.base != nil {
                        // The empty state says what to do.
                        PhotoToolKit.GlassPill { Text("Drag over anything private") }
                    }
                }
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: model.boxes.isEmpty)
            }
            .onAppear { model.pixelsPerPoint = 1 / fit.scale }
            .onChange(of: fit.scale) { _, scale in model.pixelsPerPoint = 1 / scale }
        }
    }

    private func photo(fit: PhotoToolKit.Fit) -> some View {
        ZStack {
            if let base = model.base {
                if model.info?.hasAlpha == true { PhotoToolKit.Checkerboard(dark: true) }
                Image(decorative: base, scale: 1)
                    .resizable()
                    .interpolation(fit.rect.width / CGFloat(max(base.width, 1)) > 3 ? .none : .high)
                // Every box blurred, kept ready so switching to Blur never flashes the photo underneath.
                if let blurred = model.blurred {
                    Image(decorative: blurred, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .opacity(model.style == .blur ? 1 : 0)
                }
            } else {
                PhotoToolKit.LoadingTile(dark: true)
            }
        }
        .frame(width: fit.rect.width, height: fit.rect.height)
        .position(x: fit.rect.midX, y: fit.rect.midY)
        .animation(.easeOut(duration: 0.18), value: model.style)
        .animation(.easeOut(duration: 0.18), value: model.base != nil)
        .allowsHitTesting(false)
    }

    /// Dragging on the photo draws a new box; a click clears the selection.
    private func drawLayer(fit: PhotoToolKit.Fit) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: fit.rect.width, height: fit.rect.height)
            .position(x: fit.rect.midX, y: fit.rect.midY)
            .pointerStyle(.rectSelection)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { draw($0, fit: fit) }
                    .onEnded { _ in endDraw(fit: fit) }
            )
    }

    // MARK: Gestures

    private func deselect() {
        guard model.selection != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { model.selection = nil }
    }

    private func draw(_ value: DragGesture.Value, fit: PhotoToolKit.Fit) {
        guard model.canEdit else { return }
        if drawingID == nil {
            guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
            drawingID = model.addBox(CGRect(origin: fit.pixel(value.startLocation), size: .zero))
        }
        guard let id = drawingID else { return }
        // Shift draws a square.
        let square = NSEvent.modifierFlags.contains(.shift)
        model.setRect(id, PhotoToolKit.drawnRect(from: fit.pixel(value.startLocation), to: fit.pixel(value.location),
                                                 aspect: square ? 1 : nil, in: model.bounds, minSize: 1))
    }

    private func endDraw(fit: PhotoToolKit.Fit) {
        guard let id = drawingID else {
            deselect()
            return
        }
        drawingID = nil
        // A box this small was a slip, not a redaction.
        if let box = model.box(id), box.rect.width * fit.scale < 6 || box.rect.height * fit.scale < 6 {
            withAnimation(.easeOut(duration: 0.12)) { model.remove(id) }
        }
    }

    /// Pressing a box selects it; dragging moves it.
    private func boxDrag(_ box: RedactModel.Box, fit: PhotoToolKit.Fit) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = box.rect
                    withAnimation(.easeOut(duration: 0.12)) { model.selection = box.id }
                }
                guard let start = dragStart, hypot(value.translation.width, value.translation.height) > 1 else { return }
                model.setRect(box.id, PhotoToolKit.move(start, by: fit.pixels(value.translation), in: model.bounds))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resize(_ id: UUID, _ knob: PhotoToolKit.Knob, by t: CGSize, _ phase: PhotoToolKit.BoxFrame.Phase,
                        fit: PhotoToolKit.Fit) {
        guard let box = model.box(id) else { return }
        let start = dragStart ?? box.rect
        if dragStart == nil { dragStart = start }
        // Shift keeps the shape; Option grows from the middle.
        let flags = NSEvent.modifierFlags
        let rect = PhotoToolKit.resize(start, knob: knob, by: fit.pixels(t), in: model.bounds, minSize: 8 / fit.scale,
                                       aspect: flags.contains(.shift) ? start.width / max(start.height, 1) : nil,
                                       centered: flags.contains(.option))
        model.setRect(id, rect)
        if phase == .ended { dragStart = nil }
    }

    private func move(_ id: UUID, by t: CGSize, _ phase: PhotoToolKit.BoxFrame.Phase, fit: PhotoToolKit.Fit) {
        guard let box = model.box(id) else { return }
        let start = dragStart ?? box.rect
        if dragStart == nil { dragStart = start }
        model.setRect(id, PhotoToolKit.move(start, by: fit.pixels(t), in: model.bounds))
        if phase == .ended { dragStart = nil }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: 0) {
            PhotoToolKit.Row(title: "Style", height: 32) {
                Picker("Style", selection: $model.style) {
                    Text("Solid").tag(PhotoToolKit.Redaction.Style.solid)
                    Text("Blur").tag(PhotoToolKit.Redaction.Style.blur)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
            }
            PhotoToolKit.Row(title: "Color", height: 32) {
                PhotoToolKit.ColorWell(color: model.color) { model.openColorPanel() }
                    .disabled(model.style == .blur)
                    .help(model.style == .blur ? "Blur doesn't use a color" : "Pick the fill color")
            }
            PhotoToolKit.Row(title: "Detect", height: 32) {
                HStack(spacing: 8) {
                    detectButton("Faces", .faces)
                    detectButton("Text", .text)
                }
            }
        }
        .disabled(!model.canEdit)
    }

    private func detectButton(_ title: String, _ kind: PhotoToolKit.Redaction.Detection) -> some View {
        let running = model.detecting == kind
        return Button {
            model.detect(kind)
        } label: {
            ZStack {
                Text(title).opacity(running ? 0 : 1)
                if running {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(model.detecting != nil || model.base == nil)
        .help(kind == .faces ? "Find faces and cover them" : "Find text and cover it")
    }

    // MARK: Footer

    private func reset() {
        withAnimation(.easeOut(duration: 0.18)) { model.reset() }
    }

    private func save() {
        guard model.canSave else { return }
        let boxes = model.boxes.map(\.rect)
        let reference = model.pixelSize
        let style = model.style
        let color = model.color
        session.runEach(ext: { PhotoToolKit.outputExtension(for: $0) }) { src, out, ctx in
            try PhotoToolKit.Redaction.export(src, boxes: boxes, reference: reference, style: style, color: color,
                                              format: PhotoToolKit.outputFormat(for: src), to: out, ctx: ctx)
        }
    }
}

// MARK: - A box on the photo

private struct BoxView: View {
    let box: RedactModel.Box
    let rect: CGRect
    let solid: Bool
    let color: PhotoToolKit.RGBA
    let reduceMotion: Bool
    @State private var shown: Bool
    /// Found boxes outline themselves for a moment in Blur, where there's no fill to pop in.
    @State private var flash: Bool
    @State private var hovering = false

    init(box: RedactModel.Box, rect: CGRect, solid: Bool, color: PhotoToolKit.RGBA, reduceMotion: Bool) {
        self.box = box
        self.rect = rect
        self.solid = solid
        self.color = color
        self.reduceMotion = reduceMotion
        _shown = State(initialValue: box.popDelay == nil)
        _flash = State(initialValue: box.popDelay != nil && !solid)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(color.color)
                .opacity(solid ? 1 : 0)
            Rectangle()
                .strokeBorder(Color.white.opacity(outline), lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .frame(width: max(1, rect.width), height: max(1, rect.height))
        .scaleEffect(shown || reduceMotion ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .position(x: rect.midX, y: rect.midY)
        .pointerStyle(.grabIdle)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: solid)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear {
            guard let delay = box.popDelay, !shown else { return }
            let pop: Animation = reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.34, bounce: 0.35)
            withAnimation(pop.delay(delay)) { shown = true }
            if flash {
                withAnimation(.easeOut(duration: 0.6).delay(delay + 0.6)) { flash = false }
            }
        }
    }

    private var outline: Double {
        if solid { return 0 }
        return flash ? 0.9 : (hovering ? 0.5 : 0)
    }
}

// MARK: - Model

@MainActor
private final class RedactModel: ObservableObject {
    struct Box: Identifiable, Equatable {
        let id: UUID
        /// Upright pixels of the original, top-left origin.
        var rect: CGRect
        /// Found boxes pop in one after another.
        var popDelay: Double?
    }

    let url: URL
    let info: PhotoToolKit.SourceInfo?
    @Published private(set) var base: CGImage?
    @Published private(set) var blurred: CGImage?
    @Published private(set) var failed: Bool
    @Published private(set) var boxes: [Box] = [] {
        didSet { if boxes.map(\.rect) != oldValue.map(\.rect) { renderBlur() } }
    }
    @Published var selection: UUID?
    @Published var style: PhotoToolKit.Redaction.Style = .solid
    @Published var color = PhotoToolKit.RGBA(hex: 0x000000)
    @Published private(set) var detecting: PhotoToolKit.Redaction.Detection?
    @Published private(set) var message: String?
    /// Image pixels per screen point, for arrow-key nudges.
    var pixelsPerPoint: CGFloat = 1

    private weak var hostWindow: NSWindow?
    private var keyMonitor: Any?
    private var scanImage: CGImage?
    private let worker = PhotoToolKit.LatestOnly("redact")
    private var requested = 0
    private var shown = 0
    private var messageTask: Task<Void, Never>?
    private var scans = 0
    private var holding = false

    init(url: URL) {
        self.url = url
        info = PhotoToolKit.sourceInfo(url)
        failed = info == nil
        guard info != nil else { return }
        PhotoToolKit.loadProxy(url, maxSide: 1400) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.failed = true
                return
            }
            self.base = image
            self.renderBlur()
        }
    }

    var canEdit: Bool { info != nil && !failed }
    var canSave: Bool { canEdit && !boxes.isEmpty }
    var canReset: Bool { canEdit && (!boxes.isEmpty || style != .solid || color != PhotoToolKit.RGBA(hex: 0x000000)) }
    var pixelSize: CGSize { info?.pixelSize ?? CGSize(width: 3, height: 2) }
    var bounds: CGRect { CGRect(origin: .zero, size: pixelSize) }
    var selectedBox: Box? { boxes.first { $0.id == selection } }

    func box(_ id: UUID) -> Box? { boxes.first { $0.id == id } }

    /// Adds a box and selects it.
    func addBox(_ rect: CGRect) -> UUID {
        let box = Box(id: UUID(), rect: rect)
        boxes.append(box)
        selection = box.id
        return box.id
    }

    func setRect(_ id: UUID, _ rect: CGRect) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[index].rect = rect
    }

    func remove(_ id: UUID) {
        boxes.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func reset() {
        boxes = []
        selection = nil
        style = .solid
        color = PhotoToolKit.RGBA(hex: 0x000000)
    }

    // MARK: Blur preview

    private func renderBlur() {
        guard let base, let info else { return }
        requested += 1
        let ticket = requested
        let rects = boxes.map(\.rect)
        guard !rects.isEmpty else {
            shown = ticket
            blurred = nil
            return
        }
        let scale = CGFloat(base.width) / max(info.pixelSize.width, 1)
        let longEdge = info.longEdge
        worker.submit { [weak self] in
            let input = CIImage(cgImage: base)
            let recipe = PhotoToolKit.Redaction.apply(rects, to: input, scale: scale, originalLongEdge: longEdge,
                                                      style: .blur, color: PhotoToolKit.RGBA(hex: 0))
            let image = PhotoToolKit.makeImage(recipe, extent: input.extent, space: PhotoToolKit.rgbSpace(of: base))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, ticket > self.shown else { return }
                    self.shown = ticket
                    self.blurred = image
                }
            }
        }
    }

    // MARK: Finding faces and text

    func detect(_ kind: PhotoToolKit.Redaction.Detection) {
        guard detecting == nil, let info else { return }
        detecting = kind
        scans += 1
        let scan = scans
        // The first text scan after an install can take a minute while macOS readies the reader. Say so.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scans == scan, self.detecting != nil else { return }
                self.show(kind == .text ? "First text scan takes a moment" : "Still scanning", hold: true)
            }
        }
        let url = self.url
        let cached = scanImage
        let size = info.pixelSize
        DispatchQueue.global(qos: .userInitiated).async {
            // Big enough for small faces and fine print; quick on any Mac.
            let image = cached ?? PhotoToolKit.proxy(url, maxSide: 2560)
            let found: [CGRect]? = image.flatMap { try? PhotoToolKit.Redaction.detect(kind, in: $0, pixelSize: size) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    if self.scanImage == nil { self.scanImage = image }
                    self.finish(kind, found)
                }
            }
        }
    }

    private func finish(_ kind: PhotoToolKit.Redaction.Detection, _ found: [CGRect]?) {
        detecting = nil
        if holding {
            holding = false
            withAnimation(.easeOut(duration: 0.2)) { message = nil }
        }
        guard let found else {
            show("Couldn't scan this photo")
            return
        }
        let fresh = found.filter { rect in
            !boxes.contains { PhotoToolKit.Redaction.overlap($0.rect, rect) > 0.4 }
        }
        guard !fresh.isEmpty else {
            if found.isEmpty {
                show(kind == .faces ? "No faces found" : "No text found")
            } else {
                show("Already covered")
            }
            return
        }
        // Quick stagger, never longer than half a second in total.
        let step = min(0.05, 0.45 / Double(fresh.count))
        withAnimation(.easeOut(duration: 0.12)) { selection = nil }
        boxes += fresh.enumerated().map { index, rect in
            Box(id: UUID(), rect: rect, popDelay: Double(index) * step)
        }
    }

    /// `hold` keeps the message up until the scan finishes.
    private func show(_ text: String, hold: Bool = false) {
        messageTask?.cancel()
        holding = hold
        withAnimation(.easeOut(duration: 0.18)) { message = text }
        guard !hold else { return }
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.message = nil }
        }
    }

    // MARK: Keys

    /// Delete removes the selected box; arrow keys nudge it (Shift for bigger steps).
    func attachKeys(to window: NSWindow?) {
        hostWindow = window
        guard keyMonitor == nil, window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    func detachKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let id = selection, let window = hostWindow, event.window === window,
              !(window.firstResponder is NSText), let box = box(id) else { return false }
        let step = (event.modifierFlags.contains(.shift) ? 10 : 1) * pixelsPerPoint
        var offset = CGSize.zero
        switch event.keyCode {
        case 51, 117:
            withAnimation(.easeOut(duration: 0.15)) { remove(id) }
            return true
        case 123: offset.width = -step
        case 124: offset.width = step
        case 125: offset.height = step
        case 126: offset.height = -step
        default: return false
        }
        setRect(id, PhotoToolKit.move(box.rect, by: offset, in: bounds))
        return true
    }

    // MARK: Color

    func openColorPanel() {
        PhotoToolKit.ColorPanelLink.shared.open(with: color, owner: self) { [weak self] color in
            self?.color = color
        }
    }
}

// MARK: - Engine

extension PhotoToolKit {
    enum Redaction {
        enum Style: Hashable, Sendable { case solid, blur }
        enum Detection: Hashable, Sendable { case faces, text }

        /// Covers each box (upright pixels of the original, top-left origin) in `input`, which is the
        /// original at `scale`. Blur pixelates first, so nothing can be sharpened back.
        static func apply(_ boxes: [CGRect], to input: CIImage, scale s: CGFloat, originalLongEdge: CGFloat,
                          style: Style, color: RGBA) -> CIImage {
            let extent = input.extent
            var output = input
            for box in boxes {
                let r = CGRect(x: box.minX * s, y: extent.height - box.maxY * s, width: box.width * s, height: box.height * s)
                    .integral.intersection(extent)
                guard !r.isNull, r.width >= 1, r.height >= 1 else { continue }
                let patch: CIImage
                switch style {
                case .solid:
                    patch = CIImage(color: color.ciColor).cropped(to: r)
                case .blur:
                    let block = blockSize(box, originalLongEdge: originalLongEdge) * s
                    patch = input.cropped(to: r).clampedToExtent()
                        .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(1, block / 2)])
                        .applyingFilter("CIPixellate", parameters: [
                            kCIInputScaleKey: max(1, block), kCIInputCenterKey: CIVector(x: r.minX, y: r.minY),
                        ])
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 0.9])
                        .cropped(to: r)
                }
                output = patch.composited(over: output)
            }
            return output
        }

        /// Blocks big enough that nothing can be read or rebuilt: about four across a box, never smaller
        /// than 1/80 of the photo, and about a whole line tall over a line of text.
        static func blockSize(_ box: CGRect, originalLongEdge: CGFloat) -> CGFloat {
            let short = min(box.width, box.height), long = max(box.width, box.height)
            var block = max(8, short / 4, originalLongEdge / 80)
            if long >= short * 3 { block = max(block, short * 0.6) }
            return block
        }

        /// Faces or lines of text in `image` (an upright copy), as boxes in pixels of a `pixelSize` original.
        static func detect(_ kind: Detection, in image: CGImage, pixelSize: CGSize) throws -> [CGRect] {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let bounds = CGRect(origin: .zero, size: pixelSize)
            func pixels(_ box: CGRect) -> CGRect {
                CGRect(x: box.minX * pixelSize.width, y: (1 - box.maxY) * pixelSize.height,
                       width: box.width * pixelSize.width, height: box.height * pixelSize.height)
            }
            let found: [CGRect]
            switch kind {
            case .faces:
                let request = VNDetectFaceRectanglesRequest()
                try handler.perform([request])
                found = (request.results ?? []).map { face in
                    // Vision boxes the features; grow to cover hair, ears and chin.
                    let r = pixels(face.boundingBox)
                    let w = r.width * 1.3, h = r.height * 1.45
                    return CGRect(x: r.midX - w / 2, y: r.midY - h / 2 - r.height * 0.08, width: w, height: h)
                }
            case .text:
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try handler.perform([request])
                found = (request.results ?? []).map { line in
                    let r = pixels(line.boundingBox)
                    let pad = r.height * 0.2
                    return r.insetBy(dx: -pad, dy: -pad)
                }
            }
            return found.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width >= 2 && $0.height >= 2 }
        }

        /// How much two boxes cover each other (intersection over union).
        static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            guard !i.isNull else { return 0 }
            let shared = i.width * i.height
            let union = a.width * a.height + b.width * b.height - shared
            return union > 0 ? shared / union : 0
        }

        /// Full resolution, same format. Metadata stays except GPS and place names.
        static func export(_ src: URL, boxes: [CGRect], reference: CGSize, style: Style, color: RGBA,
                           format: String, to out: URL, ctx: JobContext) throws {
            ctx.progress(0.05)
            let loaded = try ImageEngine.load(src)
            try ctx.checkCancelled()
            ctx.progress(0.35)
            let input = CIImage(cgImage: loaded.image)
            let extent = input.extent
            // The drawn-on photo maps 1:1. Other photos in a batch get the boxes at the same relative spots.
            let sx = extent.width / max(reference.width, 1), sy = extent.height / max(reference.height, 1)
            let mapped = boxes.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            let recipe = apply(mapped, to: input, scale: 1, originalLongEdge: max(extent.width, extent.height),
                               style: style, color: color)
            guard var image = PhotoToolKit.makeImage(recipe, extent: input.extent,
                                                     space: PhotoToolKit.rgbSpace(of: loaded.image),
                                                     deep: loaded.image.bitsPerComponent > 8) else {
                throw JobError.failed("Couldn't redact this photo.")
            }
            try ctx.checkCancelled()
            ctx.progress(0.75)
            if !PhotoToolKit.hasAlpha(loaded.image) { image = PhotoToolKit.droppingAlpha(image) }
            try PhotoToolKit.save(image, metadata: loaded.properties, format: format, to: out, stripLocation: true, ctx: ctx)
            ctx.progress(1)
        }
    }
}
