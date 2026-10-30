import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Annotate Photo: arrows, freehand, text, boxes, ellipses, highlights, numbered callouts,
/// a magnifier and placed images on one photo, saved as "name Annotated.png" at full size.
/// The canvas and the saved file share one drawing routine (MarkupKit.Ink), so they match.
struct AnnotateTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: AnnotateModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: AnnotateModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: AnnotateLayout.windowWidth, onClose: session.close) {
            VStack(alignment: .leading, spacing: 0) {
                CanvasArea(model: model)
                ToolStrip(model: model)
                    .padding(.top, 11)
                OptionsRow(model: model)
                    .padding(.top, 10)
                HintLine(model: model)
                    .padding(.top, 12)
            }
        } footer: {
            ToolFooter(resetEnabled: model.canReset, onReset: { model.reset() },
                       primaryTitle: "Save Annotated Copy", primaryEnabled: model.canSave, onPrimary: save)
        }
        .task { await model.load() }
    }

    private func save() {
        // Typing in progress counts: commit it first.
        model.finishEditing()
        guard model.canSave else { return }
        let doc = model.doc
        session.runEach(ext: { _ in "png" }) { src, out, ctx in
            try MarkupKit.Ink.export(src, doc: doc, to: out, job: ctx)
        }
    }
}

// MARK: - Layout

/// Sizes measured from the original window: 440 pt wide with a 416 × 492 dark canvas.
private enum AnnotateLayout {
    static let windowWidth: CGFloat = 440
    static let canvas = CGSize(width: 416, height: 492)
    static let canvasCorner: CGFloat = 12
    /// The dark stage behind the photo. A touch deeper in Dark Mode so it still separates from the window.
    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.075, green: 0.075, blue: 0.075, alpha: 1)
            : NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)
    }
    /// The raised pill in the small segmented choosers.
    static let segmentFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.2) : .white
    }
    /// How the photo sits on the canvas. Small images keep their size instead of being blown up.
    static func photoRect(_ pixelSize: CGSize, in bounds: CGRect) -> CGRect {
        MarkupKit.fit(pixelSize, in: bounds, maxScale: 1)
    }
}

// MARK: - Model

@MainActor
private final class AnnotateModel: ObservableObject {
    enum Phase: Equatable {
        case loading, ready, failed(String)
    }

    typealias Mark = MarkupKit.Mark
    typealias Tool = MarkupKit.MarkTool

    /// What the background load hands back.
    private struct Loaded: @unchecked Sendable {
        let picture: MarkupKit.Picture
        let display: CGImage
    }

    let url: URL
    @Published private(set) var phase: Phase = .loading
    /// The upright size, known before the pixels so the placeholder already has the photo's shape.
    @Published private(set) var expectedSize: CGSize?
    /// A sharp preview (up to 2400 px) used by magnifiers, plus a canvas-sized copy for everything else.
    private(set) var picture: MarkupKit.Picture?
    private(set) var display: CGImage?
    @Published private(set) var doc = MarkupKit.MarkDoc(pixelSize: CGSize(width: 1, height: 1), unit: 1)
    @Published var selection: UUID?
    @Published private(set) var tool: Tool = .arrow
    @Published private(set) var ink = MarkupKit.red
    @Published private(set) var highlight = MarkupKit.yellow
    /// Small, medium or large, shared by every tool. Small matches the original's default look.
    @Published private(set) var level = 0
    @Published private(set) var zoom: CGFloat = 2
    @Published private(set) var isEditingText = false
    @Published private(set) var notice: String?

    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    /// Repeated tweaks to one mark (picking through colors, nudging) undo as one step.
    private var coalesceKey: String?
    /// A text box that exists only while it's first typed. It joins the undo history once it has text.
    private var draft: (id: UUID, before: [Mark])?
    private var noticeTask: Task<Void, Never>?
    weak var canvas: InkCanvasView?

    init(url: URL) {
        self.url = url
    }

    var isReady: Bool { phase == .ready }
    /// The controls only grey out for a file that can't be opened, never during the short load, so they don't flicker.
    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
    var canUndo: Bool { isReady && !isEditingText && !undoStack.isEmpty }
    var canRedo: Bool { isReady && !isEditingText && !redoStack.isEmpty }
    var canReset: Bool { isReady && !doc.marks.isEmpty }
    var canSave: Bool { isReady && !doc.marks.isEmpty }

    var selectedMark: Mark? {
        guard let selection else { return nil }
        return doc.marks.first { $0.id == selection }
    }

    /// Whose options show under the tools: the selected mark's, else the active tool's.
    var contextTool: Tool { selectedMark?.tool ?? tool }

    // MARK: Loading

    func load() async {
        guard picture == nil, phase == .loading else { return }
        let url = self.url
        expectedSize = await Task.detached(priority: .userInitiated) { MarkupKit.probe(url) }.value
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> Loaded in
                // Big enough for a sharp 3× magnifier on a Retina canvas, small enough to stay quick.
                let picture = try MarkupKit.picture(url, maxPixel: 2400)
                let shown = AnnotateLayout.photoRect(picture.pixelSize, in: CGRect(origin: .zero, size: AnnotateLayout.canvas))
                let longest = Int((max(shown.width, shown.height) * 2).rounded(.up))
                let display = longest < max(picture.image.width, picture.image.height)
                    ? ImageEngine.resized(picture.image, maxSide: max(16, longest)) : picture.image
                return Loaded(picture: picture, display: display)
            }.value
            picture = loaded.picture
            display = loaded.display
            let size = loaded.picture.pixelSize
            let shown = AnnotateLayout.photoRect(size, in: CGRect(origin: .zero, size: AnnotateLayout.canvas))
            doc = MarkupKit.MarkDoc(pixelSize: size, unit: size.width / max(1, shown.width))
            phase = .ready
        } catch {
            phase = .failed("Couldn't open this photo.")
        }
    }

    // MARK: Styles

    func color(for tool: Tool) -> MarkupKit.RGBA { tool == .highlighter ? highlight : ink }
    func size(for tool: Tool) -> CGFloat { tool.sizes[min(level, tool.sizes.count - 1)] }

    var activeColor: MarkupKit.RGBA { selectedMark?.color ?? color(for: tool) }

    var activeLevel: Int {
        guard let m = selectedMark else { return level }
        let sizes = m.tool.sizes
        return sizes.indices.min { abs(sizes[$0] - m.size) < abs(sizes[$1] - m.size) } ?? level
    }

    var activeZoom: CGFloat {
        if let m = selectedMark, m.tool == .magnifier { return m.zoom }
        return zoom
    }

    func setColor(_ color: MarkupKit.RGBA) {
        let target = selectedMark?.tool ?? tool
        if target == .highlighter { highlight = color } else { ink = color }
        if let m = selectedMark, m.tool.usesInk {
            update(m.id, coalesce: "color-\(m.id)") { $0.color = color }
        }
    }

    func setLevel(_ value: Int) {
        level = value
        if let m = selectedMark, m.tool.usesInk {
            update(m.id, coalesce: "size-\(m.id)") { $0.size = m.tool.sizes[value] }
        }
    }

    func setZoom(_ value: CGFloat) {
        zoom = value
        if let m = selectedMark, m.tool == .magnifier {
            update(m.id, coalesce: "zoom-\(m.id)") { $0.zoom = value }
        }
    }

    func choose(_ newTool: Tool) {
        canvas?.endEditing()
        if newTool == .image {
            pickImage()
            return
        }
        tool = newTool
        selection = nil
    }

    // MARK: Editing

    /// Every change to the marks goes through here so undo always works.
    func commit(_ marks: [Mark], coalesce key: String? = nil) {
        guard marks != doc.marks else { return }
        if key == nil || key != coalesceKey {
            undoStack.append(doc.marks)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        coalesceKey = key
        redoStack.removeAll()
        doc.marks = marks
    }

    private func update(_ id: UUID, coalesce: String?, _ change: (inout Mark) -> Void) {
        var marks = doc.marks
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        change(&marks[i])
        if marks[i].tool == .text {
            marks[i].rect.size = MarkupKit.Ink.textSize(marks[i].text, size: marks[i].size, unit: doc.unit)
        }
        if draft?.id == id {
            // Restyling text that's still being typed: it joins the history together with the text.
            doc.marks = marks
        } else {
            commit(marks, coalesce: coalesce)
        }
    }

    func add(_ mark: Mark, select: Bool) {
        commit(doc.marks + [mark])
        selection = select ? mark.id : nil
    }

    func replace(_ mark: Mark) {
        var marks = doc.marks
        guard let i = marks.firstIndex(where: { $0.id == mark.id }) else { return }
        marks[i] = mark
        commit(marks)
    }

    func nudge(by delta: CGVector) {
        guard let id = selection else { return }
        update(id, coalesce: "nudge-\(id)") { $0 = $0.moved(by: delta) }
    }

    func deleteSelection() {
        guard let id = selection, !isEditingText else { return }
        commit(doc.marks.filter { $0.id != id })
        selection = nil
    }

    func reset() {
        canvas?.endEditing()
        guard !doc.marks.isEmpty else { return }
        commit([])
        selection = nil
    }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(doc.marks)
        restore(previous)
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(doc.marks)
        restore(next)
    }

    private func restore(_ marks: [Mark]) {
        coalesceKey = nil
        doc.marks = marks
        if let selection, !marks.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    // MARK: Text

    func addDraftText(_ mark: Mark) {
        draft = (mark.id, doc.marks)
        coalesceKey = nil
        doc.marks.append(mark)
        selection = mark.id
    }

    func setEditing(_ editing: Bool) {
        if isEditingText != editing { isEditingText = editing }
    }

    /// Called when inline editing ends. Empty text removes the box; a brand-new box becomes one undo step.
    func finishText(_ id: UUID, text: String) {
        isEditingText = false
        let before = draft?.id == id ? draft?.before : nil
        draft = nil
        guard let i = doc.marks.firstIndex(where: { $0.id == id }) else { return }
        // Keep line breaks inside the text, drop stray ones at the end.
        var kept = text
        while let last = kept.last, last.isWhitespace || last.isNewline { kept.removeLast() }
        if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let before {
                doc.marks = before
            } else {
                commit(doc.marks.filter { $0.id != id })
            }
            selection = nil
            return
        }
        var marks = doc.marks
        marks[i].text = kept
        marks[i].rect.size = MarkupKit.Ink.textSize(kept, size: marks[i].size, unit: doc.unit)
        if let before {
            undoStack.append(before)
            redoStack.removeAll()
            coalesceKey = nil
            doc.marks = marks
        } else {
            commit(marks)
        }
        selection = id
    }

    func finishEditing() {
        canvas?.endEditing()
    }

    // MARK: Placed images

    func pickImage() {
        guard isReady, let window = canvas?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to place on the photo."
        panel.prompt = "Place"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.place(url) }
        }
    }

    func place(_ url: URL) async {
        do {
            let picture = try await Task.detached(priority: .userInitiated) {
                try MarkupKit.picture(url, maxPixel: 4096)
            }.value
            place(picture.image, natural: picture.pixelSize)
        } catch {
            show(notice: "Couldn't open that image.")
        }
    }

    /// Centers the image on the photo: small images keep their size on the canvas, big ones fit 42% of it.
    func place(_ image: CGImage, natural: CGSize) {
        guard isReady else { return }
        let photo = doc.pixelSize
        let box = min(photo.width, photo.height) * 0.42
        // One image pixel per canvas point, in photo pixels.
        let asShown = CGSize(width: natural.width * doc.unit, height: natural.height * doc.unit)
        let size = MarkupKit.fit(asShown, in: CGRect(x: 0, y: 0, width: box, height: box), maxScale: 1).size
        guard size.width >= 1, size.height >= 1 else { return }
        var mark = Mark(tool: .image, color: ink, size: 1)
        mark.rect = CGRect(x: (photo.width - size.width) / 2, y: (photo.height - size.height) / 2,
                           width: size.width, height: size.height)
        mark.picture = MarkupKit.PlacedImage(image)
        add(mark, select: true)
    }

    /// ⌘V on the canvas: an image file or image data on the clipboard gets placed.
    func pasteImage() -> Bool {
        guard isReady else { return false }
        let board = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], let url = urls.first {
            Task { await place(url) }
            return true
        }
        if let image = NSImage(pasteboard: board),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            place(cg, natural: CGSize(width: cg.width, height: cg.height))
            return true
        }
        return false
    }

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Hint

    var hint: String {
        if let notice { return notice }
        switch phase {
        case .loading: return "Opening the photo."
        case .failed: return "This file can't be annotated. Try a JPEG, PNG, HEIC, TIFF or WebP."
        case .ready: break
        }
        if isEditingText { return "Type your text. Press Esc or click outside the text when you're done." }
        if let m = selectedMark {
            switch m.tool {
            case .text: return "Double-click to edit the text. Press Delete to remove it."
            case .arrow: return "Drag either end to adjust the arrow. Press Delete to remove it."
            case .rectangle, .ellipse: return "Drag a corner to resize it. Press Delete to remove it."
            case .image: return "Drag a corner to resize the image. Press Delete to remove it."
            case .magnifier: return "Drag the handle to resize, or pick a zoom. Press Delete to remove it."
            default: return "Drag it to move it. Press Delete to remove it."
            }
        }
        switch tool {
        case .arrow: return "Drag from the tail toward the arrowhead. Drag an annotation to move it."
        case .pen: return "Draw freely on the photo. Drag an annotation to move it."
        case .text: return "Click where the text goes, then type. Drag an annotation to move it."
        case .rectangle: return "Drag to draw a box. Hold Shift for a square."
        case .ellipse: return "Drag to draw an ellipse. Hold Shift for a circle."
        case .highlighter: return "Drag across what you want to highlight. Hold Shift for a straight line."
        case .number: return "Click to drop numbered callouts. They count up in order."
        case .magnifier: return "Click a detail to magnify it. Drag the handle to resize it."
        case .image: return "Choose an image to place on the photo."
        }
    }
}

// MARK: - Canvas

private struct CanvasArea: View {
    @ObservedObject var model: AnnotateModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: AnnotateLayout.canvasColor))
            switch model.phase {
            case .loading:
                placeholder
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 24, weight: .light))
                    Text(message)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.white.opacity(0.55))
                .transition(.opacity)
            case .ready:
                InkCanvas(model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: AnnotateLayout.canvas.width, height: AnnotateLayout.canvas.height)
        .clipShape(RoundedRectangle(cornerRadius: AnnotateLayout.canvasCorner, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.phase)
    }

    /// A grey card in the photo's shape while the pixels decode.
    private var placeholder: some View {
        let bounds = CGRect(origin: .zero, size: AnnotateLayout.canvas)
        let rect = model.expectedSize.map { AnnotateLayout.photoRect($0, in: bounds) } ?? bounds.insetBy(dx: 0, dy: 62)
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: rect.width, height: rect.height)
            ProgressView()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
        }
        .transition(.opacity)
    }
}

private struct InkCanvas: NSViewRepresentable {
    let model: AnnotateModel

    func makeNSView(context: Context) -> InkCanvasView {
        let view = InkCanvasView(model: model)
        model.canvas = view
        return view
    }

    func updateNSView(_ view: InkCanvasView, context: Context) {
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: InkCanvasView, coordinator: ()) {
        view.teardown()
    }
}

/// The drawing surface. Gestures work on a private copy of the mark being drawn or dragged and
/// only hand the result to the model on mouse up, so the rest of the window doesn't redraw at 60 fps.
private final class InkCanvasView: NSView, NSTextViewDelegate {
    typealias Mark = MarkupKit.Mark
    typealias Ink = MarkupKit.Ink

    private enum Interaction {
        /// A new arrow, stroke or shape following the pointer from `anchor`.
        case draw(Mark, anchor: CGPoint)
        /// A new callout or magnifier riding under the pointer until release.
        case place(Mark)
        case move(Mark, original: Mark, start: CGPoint)
        case resize(Mark, original: Mark, handle: Ink.Handle)
        case text(at: CGPoint)
    }

    private let model: AnnotateModel
    private var observer: AnyCancellable?
    private var tracking: NSTrackingArea?
    private var interaction: Interaction?
    private var editor: InlineTextView?
    private var editingID: UUID?
    private var editorUndo: UndoManager?
    private var styleSyncScheduled = false

    init(model: AnnotateModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Photo to annotate")
        observer = model.objectWillChange.sink { [weak self] _ in self?.modelWillChange() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        guard let window else { return }
        installKeyMonitor()
        // Take focus so Delete, the arrow keys and the tool keys work without clicking first.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.window === window, self.editor == nil else { return }
            if !(window.firstResponder is NSTextView) { window.makeFirstResponder(self) }
        }
    }

    // MARK: Esc and Return

    private var keyMonitor: Any?

    /// The window's own shortcuts (Esc closes it, Return saves) answer before the canvas and the text box
    /// do, which would throw the annotations away mid-edit. A local monitor sees the key first instead.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.interceptKey(event) } ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Esc finishes the text or lets go of the selection, and only then closes the window.
    /// Return inside the text starts a new line. Returns true when the key was used here.
    private func interceptKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, Self.flags(event).isEmpty else { return false }
        switch event.keyCode {
        case 53: // esc
            if let editor {
                // An input method composing a character gets its Esc.
                if editor.hasMarkedText() { editor.keyDown(with: event) } else { endEditing() }
                return true
            }
            guard model.selection != nil else { return false }
            model.selection = nil
            return true
        case 36, 76: // return, enter
            guard let editor, window.firstResponder === editor else { return false }
            editor.keyDown(with: event)
            return true
        default:
            return false
        }
    }

    private func modelWillChange() {
        needsDisplay = true
        guard editor != nil, !styleSyncScheduled else { return }
        styleSyncScheduled = true
        // objectWillChange fires before the change lands, so restyle on the next turn.
        Task { @MainActor [weak self] in
            self?.styleSyncScheduled = false
            self?.syncEditorStyle()
        }
    }

    // MARK: Geometry

    private var photoRect: CGRect { AnnotateLayout.photoRect(model.doc.pixelSize, in: bounds) }
    /// View points per photo pixel.
    private var scale: CGFloat { photoRect.width / max(1, model.doc.pixelSize.width) }

    private func toPhoto(_ p: CGPoint) -> CGPoint {
        let r = photoRect, s = max(scale, 0.0001)
        return CGPoint(x: (p.x - r.minX) / s, y: (p.y - r.minY) / s)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = photoRect, s = scale
        return CGPoint(x: r.minX + p.x * s, y: r.minY + p.y * s)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let o = toView(rect.origin), s = scale
        return CGRect(x: o.x, y: o.y, width: rect.width * s, height: rect.height * s)
    }

    private func clampToPhoto(_ p: CGPoint) -> CGPoint {
        let size = model.doc.pixelSize
        return CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }

    /// The marks with whatever the pointer is doing right now applied.
    private var liveDoc: MarkupKit.MarkDoc {
        var doc = model.doc
        switch interaction {
        case .draw(let m, _), .place(let m):
            doc.marks.append(m)
        case .move(let m, _, _), .resize(let m, _, _):
            if let i = doc.marks.firstIndex(where: { $0.id == m.id }) { doc.marks[i] = m }
        case .text, nil:
            break
        }
        return doc
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard model.isReady, let picture = model.picture, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = photoRect
        let doc = liveDoc
        if picture.hasAlpha { drawChecker(in: r, ctx: ctx) }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        // The base photo from the canvas-sized copy; magnifiers enlarge the sharper preview.
        Ink.drawImage(model.display ?? picture.image, in: CGRect(origin: .zero, size: doc.pixelSize), ctx: ctx)
        Ink.draw(doc, photo: nil, lens: picture.image, in: ctx, hiding: editingID)
        ctx.restoreGState()
        drawSelection(doc: doc, ctx: ctx)
        if let editor {
            // The box being typed in, so a fresh one on a busy photo is easy to spot. layoutEditor adds 6 pt for the caret.
            let f = editor.frame
            outline(CGPath(roundedRect: CGRect(x: f.minX - 5, y: f.minY - 3, width: f.width + 4, height: f.height + 6),
                           cornerWidth: 3, cornerHeight: 3, transform: nil), ctx: ctx)
        }
    }

    /// The dashed white line with a soft dark edge that marks the selection, readable on any photo.
    private func outline(_ path: CGPath, ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawChecker(in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(r)
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        let s: CGFloat = 8
        var row = 0
        var y = r.minY
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : s)
            while x < r.maxX {
                ctx.fill(CGRect(x: x, y: y, width: s, height: s))
                x += 2 * s
            }
            y += s
            row += 1
        }
        ctx.restoreGState()
    }

    private func drawSelection(doc: MarkupKit.MarkDoc, ctx: CGContext) {
        guard let id = model.selection, id != editingID, let m = doc.marks.first(where: { $0.id == id }) else { return }
        if m.tool != .arrow {
            let box = toView(Ink.bounds(m, unit: doc.unit)).insetBy(dx: -4, dy: -4)
            let round = m.tool == .number || m.tool == .magnifier
            outline(round ? CGPath(ellipseIn: box, transform: nil) : CGPath(rect: box, transform: nil), ctx: ctx)
        }
        for (_, p) in Ink.handles(m) { drawHandle(at: toView(p), ctx: ctx) }
    }

    private func drawHandle(at p: CGPoint, ctx: CGContext) {
        let d: CGFloat = 9
        let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(ToolStyle.nsOrange.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
    }

    // MARK: Hit testing

    private func handle(at viewPoint: CGPoint, of m: Mark) -> Ink.Handle? {
        Ink.handles(m).first { MarkupKit.distance(toView($0.1), viewPoint) <= 8 }?.0
    }

    private func mark(at viewPoint: CGPoint) -> Mark? {
        let p = toPhoto(viewPoint)
        let unit = model.doc.unit
        let tolerance = 5 / max(scale, 0.0001)
        return model.doc.marks.last { Ink.hits($0, p, tolerance: tolerance, unit: unit) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if editor != nil {
            // A click outside the text box finishes it and does nothing else.
            endEditing()
            return
        }
        window?.makeFirstResponder(self)
        guard model.isReady else { return }

        if let selected = model.selectedMark, let h = handle(at: viewPoint, of: selected) {
            interaction = .resize(selected, original: selected, handle: h)
            return
        }
        if let hit = mark(at: viewPoint) {
            model.selection = hit.id
            if event.clickCount >= 2, hit.tool == .text {
                beginEditing(hit.id, selectAll: true)
                return
            }
            interaction = .move(hit, original: hit, start: toPhoto(viewPoint))
            NSCursor.closedHand.set()
            return
        }

        model.selection = nil
        guard photoRect.contains(viewPoint) else { return }
        let p = clampToPhoto(toPhoto(viewPoint))
        let tool = model.tool
        var m = Mark(tool: tool, color: model.color(for: tool), size: model.size(for: tool))
        switch tool {
        case .arrow:
            m.points = [p, p]
            interaction = .draw(m, anchor: p)
        case .pen, .highlighter:
            m.points = [p]
            interaction = .draw(m, anchor: p)
        case .rectangle, .ellipse:
            m.rect = CGRect(origin: p, size: .zero)
            interaction = .draw(m, anchor: p)
        case .number:
            m.points = [p]
            interaction = .place(m)
        case .magnifier:
            let radius = 52 * model.doc.unit
            m.rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            m.zoom = model.zoom
            interaction = .place(m)
        case .text:
            interaction = .text(at: p)
        case .image:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = toPhoto(viewPoint)
        let shift = event.modifierFlags.contains(.shift)
        switch interaction {
        case .draw(var m, let anchor):
            let q = clampToPhoto(p)
            switch m.tool {
            case .arrow:
                m.points[1] = shift ? Ink.snap45(from: anchor, to: q) : q
            case .pen:
                if let last = m.points.last, MarkupKit.distance(last, q) * scale >= 1.2 { m.points.append(q) }
            case .highlighter:
                if shift {
                    m.points = [anchor, clampToPhoto(Ink.snap45(from: anchor, to: q))]
                } else if let last = m.points.last, MarkupKit.distance(last, q) * scale >= 1.2 {
                    m.points.append(q)
                }
            case .rectangle, .ellipse:
                var w = q.x - anchor.x, h = q.y - anchor.y
                if shift {
                    let side = max(abs(w), abs(h))
                    w = w < 0 ? -side : side
                    h = h < 0 ? -side : side
                }
                m.rect = CGRect(x: anchor.x, y: anchor.y, width: w, height: h).standardized
            default:
                break
            }
            self.interaction = .draw(m, anchor: anchor)
        case .place(var m):
            let q = clampToPhoto(p)
            if m.tool == .number {
                m.points = [q]
            } else {
                m.rect.origin = CGPoint(x: q.x - m.rect.width / 2, y: q.y - m.rect.height / 2)
            }
            self.interaction = .place(m)
        case .move(_, let original, let start):
            var delta = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            if shift {
                if abs(delta.dx) > abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
            }
            self.interaction = .move(keepOnPhoto(original.moved(by: delta)), original: original, start: start)
        case .resize(_, let original, let handle):
            let resized = Ink.resized(original, handle: handle, to: p, constrain: shift, unit: model.doc.unit)
            self.interaction = .resize(resized, original: original, handle: handle)
        case .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction else { return }
        self.interaction = nil
        switch interaction {
        case .draw(let m, _):
            if isSubstantial(m) {
                // Shapes stay selected so their handles are right there; freehand strokes don't.
                model.add(m, select: m.tool == .arrow || m.tool == .rectangle || m.tool == .ellipse)
            }
        case .place(let m):
            model.add(m, select: m.tool == .magnifier)
        case .move(let m, let original, _), .resize(let m, let original, _):
            if m != original { model.replace(m) }
        case .text(let p):
            beginNewText(at: p)
        }
        needsDisplay = true
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Clicks shouldn't leave specks: tiny arrows, strokes and shapes are dropped.
    private func isSubstantial(_ m: Mark) -> Bool {
        switch m.tool {
        case .arrow:
            return m.points.count == 2 && MarkupKit.distance(m.points[0], m.points[1]) * scale >= 6
        case .pen, .highlighter:
            guard m.points.count >= 2 else { return false }
            var length: CGFloat = 0
            for i in 1..<m.points.count { length += MarkupKit.distance(m.points[i - 1], m.points[i]) }
            return length * scale >= 3
        case .rectangle, .ellipse:
            let r = m.rect.standardized
            return r.width * scale >= 4 && r.height * scale >= 4
        default:
            return true
        }
    }

    /// Lets a mark hang off the edge but never lose its middle off the photo.
    private func keepOnPhoto(_ m: Mark) -> Mark {
        let b = Ink.bounds(m, unit: model.doc.unit)
        let size = model.doc.pixelSize
        let cx = min(max(b.midX, 0), size.width), cy = min(max(b.midY, 0), size.height)
        guard cx != b.midX || cy != b.midY else { return m }
        return m.moved(by: CGVector(dx: cx - b.midX, dy: cy - b.midY))
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func updateCursor(at viewPoint: CGPoint) {
        guard interaction == nil else { return }
        cursor(at: viewPoint).set()
    }

    private func cursor(at viewPoint: CGPoint) -> NSCursor {
        guard model.isReady else { return .arrow }
        if let editor, editor.frame.contains(viewPoint) { return .iBeam }
        if let selected = model.selectedMark, let h = handle(at: viewPoint, of: selected) {
            switch h {
            case .tail, .head: return .crosshair
            case .radius: return NSCursor.frameResize(position: .bottomRight, directions: .all)
            case .corner(let i):
                let positions: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
                return NSCursor.frameResize(position: positions[i % 4], directions: .all)
            }
        }
        if mark(at: viewPoint) != nil { return .openHand }
        guard photoRect.contains(viewPoint) else { return .arrow }
        return model.tool == .text ? .iBeam : .crosshair
    }

    // MARK: Keyboard

    private static func flags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    override func keyDown(with event: NSEvent) {
        guard model.isReady, editor == nil else { return super.keyDown(with: event) }
        let flags = Self.flags(event)
        switch event.keyCode {
        case 51, 117: // delete, forward delete (Esc is handled by the key monitor)
            if model.selection != nil { model.deleteSelection(); return }
        case 123, 124, 125, 126: // arrows nudge by a point, or ten with Shift
            if model.selection != nil, flags.subtracting(.shift).isEmpty {
                let step = (flags.contains(.shift) ? 10 : 1) / max(scale, 0.0001)
                let delta: CGVector
                switch event.keyCode {
                case 123: delta = CGVector(dx: -step, dy: 0)
                case 124: delta = CGVector(dx: step, dy: 0)
                case 125: delta = CGVector(dx: 0, dy: step)
                default: delta = CGVector(dx: 0, dy: -step)
                }
                model.nudge(by: delta)
                return
            }
        default:
            break
        }
        if flags.subtracting(.shift).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = MarkupKit.MarkTool.allCases.first(where: { $0.key == key }) {
            model.choose(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editor == nil, model.isReady, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if Self.flags(event) == .command, event.charactersIgnoringModifiers?.lowercased() == "v", model.pasteImage() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Inline text

    private func beginNewText(at p: CGPoint) {
        let size = model.size(for: .text)
        let lineHeight = Ink.textSize("X", size: size, unit: model.doc.unit).height
        var m = Mark(tool: .text, color: model.color(for: .text), size: size)
        m.rect = CGRect(x: p.x, y: max(0, p.y - lineHeight / 2), width: 0, height: lineHeight)
        model.addDraftText(m)
        beginEditing(m.id, selectAll: false)
    }

    /// The same font, color and shadow the saved file uses, at canvas scale.
    private func editorAttributes(for m: Mark) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        let blur = (1.6 + 3 * 0.35) * model.doc.unit * scale
        if m.color.isDark {
            shadow.shadowColor = NSColor(white: 1, alpha: 0.6)
            shadow.shadowOffset = .zero
        } else {
            shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
            shadow.shadowOffset = NSSize(width: 0, height: -0.8 * model.doc.unit * scale)
        }
        shadow.shadowBlurRadius = blur
        return [.font: Ink.textFont(m.size * model.doc.unit * scale), .foregroundColor: m.color.ns, .shadow: shadow]
    }

    private func beginEditing(_ id: UUID, selectAll: Bool) {
        guard let m = model.doc.marks.first(where: { $0.id == id }) else { return }
        if editor != nil { endEditing() }
        let attributes = editorAttributes(for: m)

        // TextKit 1, so the text lays out exactly like the saved file's string drawing.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 1e6, height: 1e6))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = InlineTextView(frame: CGRect(origin: toView(m.rect.origin), size: CGSize(width: 40, height: 20)),
                                      textContainer: container)
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 1e6, height: 1e6)
        textView.typingAttributes = attributes
        textView.insertionPointColor = m.color.ns
        textView.setAccessibilityLabel("Annotation text")
        storage.setAttributedString(NSAttributedString(string: m.text, attributes: attributes))

        editorUndo = UndoManager()
        editor = textView
        editingID = id
        addSubview(textView)
        layoutEditor()
        model.setEditing(true)
        window?.makeFirstResponder(textView)
        let length = (m.text as NSString).length
        textView.setSelectedRange(selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0))
        needsDisplay = true
    }

    private func layoutEditor() {
        guard let editor, let container = editor.textContainer, let layout = editor.layoutManager,
              let id = editingID, let m = model.doc.marks.first(where: { $0.id == id }) else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let font = editor.typingAttributes[.font] as? NSFont ?? Ink.textFont(14)
        let lineHeight = layout.defaultLineHeight(for: font)
        let origin = toView(m.rect.origin)
        // A little room on the right for the caret.
        editor.frame = CGRect(x: origin.x, y: origin.y, width: ceil(max(used.width, 1)) + 6,
                              height: ceil(max(used.height, lineHeight)))
        needsDisplay = true
    }

    private func syncEditorStyle() {
        guard let editor, let id = editingID, let m = model.doc.marks.first(where: { $0.id == id }) else { return }
        let attributes = editorAttributes(for: m)
        let oldFont = editor.typingAttributes[.font] as? NSFont
        let oldColor = editor.typingAttributes[.foregroundColor] as? NSColor
        let newFont = attributes[.font] as? NSFont
        let newColor = attributes[.foregroundColor] as? NSColor
        guard oldFont?.pointSize != newFont?.pointSize || oldColor != newColor else { return }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.textStorage?.setAttributes(attributes, range: range)
        editor.typingAttributes = attributes
        editor.insertionPointColor = m.color.ns
        layoutEditor()
    }

    /// Commits whatever was typed. Safe to call when nothing is being edited.
    func endEditing() {
        guard let editor, let id = editingID else { return }
        let text = editor.string
        self.editor = nil
        editingID = nil
        editorUndo = nil
        editor.delegate = nil
        let wasFocused = window?.firstResponder === editor
        editor.removeFromSuperview()
        model.finishText(id, text: text)
        if wasFocused { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    /// The window is closing: drop the editor without touching the model.
    func teardown() {
        removeKeyMonitor()
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil
        editingID = nil
        observer = nil
    }

    func textDidChange(_ notification: Notification) {
        layoutEditor()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        editorUndo
    }
}

/// The text box used while typing. The app has no menu bar, so the usual editing shortcuts live here.
private final class InlineTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case (.command, "x"): cut(nil); return true
        case (.command, "c"): copy(nil); return true
        case (.command, "v"): pasteAsPlainText(nil); return true
        case (.command, "a"): selectAll(nil); return true
        case (.command, "z"):
            if undoManager?.canUndo == true { undoManager?.undo() }
            return true
        case ([.command, .shift], "z"):
            if undoManager?.canRedo == true { undoManager?.redo() }
            return true
        case (.command, "\r"):
            // ⌘Return finishes the text, like Esc. The delegate gets the command first.
            doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - Tool strip

private struct ToolStrip: View {
    @ObservedObject var model: AnnotateModel
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MarkupKit.MarkTool.allCases) { tool in
                ToolButton(tool: tool, selected: model.tool == tool, namespace: selectionSpace) {
                    model.choose(tool)
                }
            }
        }
        .disabled(model.isFailed)
        .animation(MarkupKit.spring(reduceMotion), value: model.tool)
    }
}

private struct ToolButton: View {
    let tool: MarkupKit.MarkTool
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering && isEnabled && !selected ? 0.1 : 0.06))
                    if selected {
                        // One orange pill that slides between tools.
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(ToolStyle.orange)
                            .matchedGeometryEffect(id: "selected tool", in: namespace)
                    }
                }
                // Disabled dims the whole button, the orange pill included.
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help("\(tool.title)  \(tool.key.uppercased())")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A quick squeeze on press.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

// MARK: - Options row

private struct OptionsRow: View {
    @ObservedObject var model: AnnotateModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tool = model.contextTool
        HStack(spacing: 8) {
            if tool.usesInk {
                MarkupKit.ColorWell(color: model.activeColor, swatches: MarkupKit.inkSwatches) { model.setColor($0) }
                    .transition(.opacity)
                let lines = tool != .text && tool != .number
                Segments(options: [0, 1, 2],
                         selection: Binding(get: { model.activeLevel }, set: { model.setLevel($0) }),
                         name: { ["Small", "Medium", "Large"][$0] }) { level in
                    Image(nsImage: MarkupKit.SizeGlyph.image(lines: lines, level: level))
                        .renderingMode(.template)
                }
                .help(lines ? "Line width" : (tool == .text ? "Text size" : "Callout size"))
                .transition(.opacity)
            }
            if tool == .magnifier {
                Segments(options: [CGFloat(1.5), 2, 3], selection: Binding(get: { model.activeZoom }, set: { model.setZoom($0) }),
                         segmentWidth: 34, name: { "Zoom \(Self.zoomLabel($0))" }) { zoom in
                    Text(Self.zoomLabel(zoom))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                }
                .help("Zoom")
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "arrow.uturn.backward", title: "Undo") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            IconButton(symbol: "trash", title: "Delete") { model.deleteSelection() }
                .disabled(model.selection == nil || model.isEditingText)
        }
        .frame(height: 20)
        .background {
            // Redo has no button in the original; it lives on ⇧⌘Z.
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .disabled(model.isFailed)
        .animation(MarkupKit.spring(reduceMotion), value: tool)
    }

    private static func zoomLabel(_ zoom: CGFloat) -> String {
        zoom == zoom.rounded() ? "\(Int(zoom))×" : String(format: "%.1f×", zoom)
    }
}

/// A compact segmented control in the window's style: a grey track and a raised pill that slides.
private struct Segments<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var segmentWidth: CGFloat = 28
    let name: (Value) -> String
    @ViewBuilder let label: (Value) -> Label
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { value in
                let on = value == selection
                Button {
                    selection = value
                } label: {
                    label(value)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(width: segmentWidth, height: 20)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(Color(nsColor: AnnotateLayout.segmentFill))
                                    .shadow(color: .black.opacity(0.14), radius: 0.6, y: 0.5)
                                    .padding(2)
                                    .matchedGeometryEffect(id: "segment", in: space)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name(value))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
        .opacity(isEnabled ? 1 : 0.5)
        .animation(MarkupKit.spring(reduceMotion), value: selection)
    }
}

/// The small grey square-cornered buttons on the right of the options row (Undo, Delete).
private struct IconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isEnabled ? 0.75 : 0.25))
                .frame(width: 32, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isEnabled ? (hovering ? 0.11 : 0.075) : 0.04))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct HintLine: View {
    @ObservedObject var model: AnnotateModel

    var body: some View {
        Text(model.hint)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.15), value: model.hint)
    }
}
