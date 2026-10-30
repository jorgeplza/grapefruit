import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Float: a small shelf that holds files above every window. Drag them out when you're ready,
/// drop more on it, or pin it so it tucks into the screen edge.
@MainActor
enum FloatShelf {
    private static var shelves: [ShelfController] = []

    static func show(_ urls: [URL], near anchor: NSPoint) {
        let controller = ShelfController(urls: urls)
        shelves.append(controller)
        controller.onClose = { [weak controller] in
            shelves.removeAll { $0 === controller }
        }
        let offset = CGFloat(shelves.count - 1) * 18
        controller.present(at: NSPoint(x: anchor.x + offset, y: anchor.y - offset))
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published var urls: [URL]
    @Published var thumbnails: [URL: NSImage] = [:]
    @Published var hovering = false
    @Published var pinned = false
    @Published var tucked = false
    @Published var dropTargeted = false
    @Published var tuckedOnLeft = false

    init(urls: [URL]) { self.urls = urls }

    var title: String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
    }

    var subtitle: String {
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
    }

    func loadThumbnails() {
        for url in urls.prefix(3) where thumbnails[url] == nil {
            thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                guard let image = rep?.nsImage else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.thumbnails[url] = image }
                }
            }
        }
    }
}

@MainActor
final class ShelfController: NSObject {
    static let size = NSSize(width: 168, height: 188)
    static let tuckVisible: CGFloat = 30

    let model: ShelfModel
    var onClose: (() -> Void)?
    private var panel: ShelfPanel!
    private var tuckWork: DispatchWorkItem?

    init(urls: [URL]) {
        model = ShelfModel(urls: urls)
        super.init()
        let frame = NSRect(origin: .zero, size: Self.size)
        panel = ShelfPanel(contentRect: frame)
        let root = NSView(frame: frame)
        let hosting = NSHostingView(rootView: ShelfView(model: model, onClose: { [weak self] in self?.close() },
                                                        onPin: { [weak self] in self?.togglePin() }))
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        let drag = ShelfDragView(frame: frame)
        drag.autoresizingMask = [.width, .height]
        drag.controller = self
        root.addSubview(hosting)
        root.addSubview(drag)
        panel.contentView = root
        model.loadThumbnails()
    }

    func present(at anchor: NSPoint) {
        var frame = NSRect(x: anchor.x - Self.size.width / 2, y: anchor.y - Self.size.height / 2,
                           width: Self.size.width, height: Self.size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        tuckWork?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                self?.onClose?()
            }
        })
    }

    // MARK: Pinning

    func togglePin() {
        model.pinned.toggle()
        panel.collectionBehavior = model.pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        if model.pinned {
            tuck(after: 0.6)
        } else {
            untuck()
        }
    }

    func hoverChanged(_ inside: Bool) {
        model.hovering = inside
        guard model.pinned else { return }
        if inside { untuck() } else { tuck(after: 0.5) }
    }

    /// Slide into the nearest side edge, leaving a tab to grab.
    private func tuck(after delay: TimeInterval) {
        tuckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.pinned, !self.model.hovering, !self.model.dropTargeted else { return }
                guard let visible = self.panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
                var frame = self.panel.frame
                let left = frame.midX < visible.midX
                self.model.tuckedOnLeft = left
                frame.origin.x = left ? visible.minX - frame.width + Self.tuckVisible : visible.maxX - Self.tuckVisible
                self.model.tucked = true
                self.slide(to: frame)
            }
        }
        tuckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func untuck() {
        tuckWork?.cancel()
        guard model.tucked, let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = model.tuckedOnLeft ? visible.minX + 8 : visible.maxX - frame.width - 8
        model.tucked = false
        slide(to: frame)
    }

    private func slide(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Files in and out

    func add(_ urls: [URL]) {
        let fresh = urls.filter { !model.urls.contains($0) }
        guard !fresh.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.urls.append(contentsOf: fresh)
        }
        model.loadThumbnails()
    }

    func draggedOut(operation: NSDragOperation) {
        // Files Finder moved elsewhere are gone from here too.
        let remaining = model.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if remaining.isEmpty {
            close()
        } else if remaining.count != model.urls.count {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.urls = remaining }
        }
    }

    func dropTargeted(_ on: Bool) {
        model.dropTargeted = on
        if on { untuck() } else if model.pinned && !model.hovering { tuck(after: 0.6) }
    }

    func open() {
        NSWorkspace.shared.open(model.urls, withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

final class ShelfPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
}

/// Starts file drags from the shelf, moves the shelf by its top strip, and takes drops.
final class ShelfDragView: NSView, NSDraggingSource {
    weak var controller: ShelfController?
    private var downEvent: NSEvent?
    private var movingWindow = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Inset matches the card inside the panel (room for its shadow).
    private var card: NSRect { bounds.insetBy(dx: ShelfView.margin, dy: ShelfView.margin) }
    private var strip: NSRect { NSRect(x: card.minX, y: card.maxY - 32, width: card.width, height: 32) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard card.contains(p) else { return nil }
        // Let the close and pin buttons get their own clicks.
        if strip.contains(p), p.x < card.minX + 34 || p.x > card.maxX - 34 { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: card, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.hoverChanged(true) }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.hoverChanged(false) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downEvent = event
        movingWindow = strip.contains(p)
        if movingWindow { window?.performDrag(with: event) }
        if event.clickCount == 2 { MainActor.assumeIsolated { controller?.open() } }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !movingWindow, let down = downEvent, let controller else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        downEvent = nil
        let urls = MainActor.assumeIsolated { controller.model.urls }
        let origin = convert(start, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = MainActor.assumeIsolated { controller.model.thumbnails[url] } ?? NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 64
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                                  contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { controller?.draggedOut(operation: operation) }
    }

    // MARK: Drops onto the shelf

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard (sender.draggingSource as? ShelfDragView) !== self else { return [] }
        MainActor.assumeIsolated { controller?.dropTargeted(true) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.dropTargeted(false) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DragMonitor.fileURLs(on: sender.draggingPasteboard)
        MainActor.assumeIsolated {
            controller?.dropTargeted(false)
            controller?.add(urls)
        }
        return !urls.isEmpty
    }
}

struct ShelfView: View {
    static let margin: CGFloat = 14
    @ObservedObject var model: ShelfModel
    var onClose: () -> Void
    var onPin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ShelfButton(symbol: "xmark", active: false, action: onClose)
                    .opacity(model.hovering ? 1 : 0)
                Spacer()
                ShelfButton(symbol: model.pinned ? "pin.fill" : "pin", active: model.pinned, action: onPin)
                    .opacity(model.hovering || model.pinned ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)

            ZStack(alignment: .topTrailing) {
                ZStack {
                    ForEach(Array(model.urls.prefix(3).enumerated().reversed()), id: \.element) { index, url in
                        Thumbnail(image: model.thumbnails[url])
                            .rotationEffect(.degrees(model.urls.count > 1 ? [0, -7, 6][index] : 0))
                            .offset(x: model.urls.count > 1 ? [0, -9, 9][index] : 0, y: CGFloat(index) * 2)
                    }
                }
                .frame(width: 96, height: 84)
                .scaleEffect(model.dropTargeted ? 1.06 : 1)

                if model.urls.count > 1 {
                    Text("\(model.urls.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(ToastStyle.orange))
                        .offset(x: 6, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            VStack(spacing: 2) {
                Text(model.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ToastStyle.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.hovering ? "Drag out, or drop more here" : model.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ToastStyle.detail)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ToastStyle.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(model.dropTargeted ? ToastStyle.orange : ToastStyle.border,
                              lineWidth: model.dropTargeted ? 2 : 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 9)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .padding(Self.margin)
        .animation(.easeOut(duration: 0.16), value: model.hovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: model.dropTargeted)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.urls)
    }
}

private struct Thumbnail: View {
    var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.92))
            }
        }
        .frame(maxWidth: 72, maxHeight: 72)
        .shadow(color: .black.opacity(0.14), radius: 3, x: 0, y: 2)
    }
}

private struct ShelfButton: View {
    var symbol: String
    var active: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? .white : ToastStyle.closeGlyph)
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? ToastStyle.orange : (hovering ? Color(white: 0.87) : ToastStyle.closeDisc)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
