import AppKit
import SwiftUI

/// What the user dropped the file on.
enum WheelChoice {
    case convert(String)
    case tool(ToolID)
    case action(ActionID)
}

/// Floats the wheel under the cursor mid-drag and turns a drop on a petal into a choice.
@MainActor
final class WheelController {
    let model = WheelModel()
    var onChoose: ((WheelChoice, [URL], NSPoint) -> Void)?

    private let metrics = WheelMetrics.standard
    private let feedback = Feedback()
    private var panel: WheelPanel!
    private var zoomView: NSView!
    private var urls: [URL] = []
    private var formats: [String] = []
    private var anchor = NSPoint.zero
    private var closeWork: DispatchWorkItem?
    private var swapWork: DispatchWorkItem?
    private(set) var isOpen = false

    init() {
        build()
    }

    private func build() {
        let side = metrics.canvas
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        panel = WheelPanel(contentRect: bounds)

        let root = NSView(frame: bounds)
        root.wantsLayer = true

        zoomView = NSView(frame: bounds)
        zoomView.wantsLayer = true
        zoomView.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: WheelView(model: model, metrics: metrics))
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]

        let drop = WheelDropView(frame: bounds)
        drop.autoresizingMask = [.width, .height]
        drop.controller = self

        zoomView.addSubview(hosting)
        root.addSubview(zoomView)
        root.addSubview(drop)
        panel.contentView = root
    }

    // MARK: Opening and switching

    func show(mode: WheelMode, urls: [URL], at point: NSPoint) {
        closeWork?.cancel()
        self.urls = urls
        formats = urls.map { Catalog.format(of: $0) ?? "" }
        let targets = makeTargets(mode)

        if isOpen {
            guard mode != model.mode else { return }
            switchWheel(to: mode, targets: targets)
            return
        }

        swapWork?.cancel()
        model.mode = mode
        model.targets = targets
        model.highlighted = nil
        model.popped = nil
        model.leaving = false
        model.hubSummary = summary()
        model.emptyMessage = emptyMessage(mode, targets)
        model.generation += 1

        anchor = clamped(point)
        let side = metrics.canvas
        panel.setFrame(NSRect(x: anchor.x - side / 2, y: anchor.y - side / 2, width: side, height: side), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        isOpen = true
        bloom()
        feedback.prepare()
    }

    /// Switch wheels while open: the old segments sink, the new ones cut in.
    private func switchWheel(to mode: WheelMode, targets: [WheelTarget]) {
        swapWork?.cancel()
        let message = emptyMessage(mode, targets)
        model.highlighted = nil
        model.leaving = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    self.model.emptyMessage = message
                }
                self.model.mode = mode
                self.model.targets = targets
                self.model.highlighted = nil
                self.model.leaving = false
                self.model.generation += 1
            }
        }
        swapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
    }

    /// The mouse went up somewhere.
    func dragEnded() {
        guard isOpen else { return }
        let mouse = NSEvent.mouseLocation
        let onWheel = hypot(mouse.x - anchor.x, mouse.y - anchor.y) <= metrics.hitOuter * metrics.scale
        if onWheel && model.highlighted != nil {
            // A drop on a petal is on its way; it closes the wheel when it lands.
            scheduleClose(after: 0.4)
        } else {
            close()
        }
    }

    /// Fade out while shrinking a little.
    func close() {
        guard isOpen else { return }
        isOpen = false
        closeWork?.cancel()
        swapWork?.cancel()
        feedback.idle()
        animateZoom(scales: [1, 0.9], opacities: [1, 0], times: [0, 1], duration: 0.14,
                    curve: CAMediaTimingFunction(name: .easeIn))
        hide(after: 0.14)
    }

    private func hide(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                self.zoomView.layer?.removeAllAnimations()
                self.model.highlighted = nil
                self.model.popped = nil
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleClose(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Drag destination

    func dragMoved(_ info: NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard isOpen, model.emptyMessage == nil else { return [] }
        let p = view.convert(info.draggingLocation, from: nil)
        // Back into the wheel's own sizes, since it's shown at `scale`.
        let offset = CGPoint(x: (p.x - view.bounds.midX) / metrics.scale, y: (view.bounds.midY - p.y) / metrics.scale)
        let index = WheelGeometry.petal(at: offset, count: model.targets.count, metrics: metrics)
        light(index)
        guard index != nil else { return [] }
        let allowed = info.draggingSourceOperationMask
        if allowed.contains(.copy) { return .copy }
        if allowed.contains(.generic) { return .generic }
        return allowed.contains(.move) ? .move : []
    }

    func dragLeft() {
        light(nil)
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard isOpen, let index = model.highlighted, index < model.targets.count else { return false }
        let dropped = DragMonitor.fileURLs(on: info.draggingPasteboard)
        let files = dropped.isEmpty ? urls : dropped
        guard let choice = choice(for: model.targets[index]) else { return false }
        let at = anchor
        squeeze(index)
        // Act after the drag session has wrapped up.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChoose?(choice, files, at) }
        }
        return true
    }

    var hasLitPetal: Bool { model.highlighted != nil }

    /// Drop: the segment pops out, then the whole fruit squeezes shut.
    private func squeeze(_ index: Int) {
        isOpen = false
        closeWork?.cancel()
        swapWork?.cancel()
        feedback.idle()
        model.popped = index
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.animateZoom(scales: [1, 0.95, 0.86], opacities: [1, 0.62, 0], times: [0, 0.35, 1], duration: 0.34,
                                 curve: CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1))
                self.hide(after: 0.34)
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
    }

    private func light(_ index: Int?) {
        guard !model.leaving, index != model.highlighted else { return }
        model.highlighted = index
        if index != nil { feedback.tick() }
    }

    // MARK: Content

    private func makeTargets(_ mode: WheelMode) -> [WheelTarget] {
        switch mode {
        case .conversions:
            return Catalog.conversionTargets(forFormats: formats)
                .filter { Capabilities.canProduce($0, from: formats) }
                .map { WheelTarget(id: "convert:\($0)", label: Catalog.displayName($0), symbol: nil,
                                   hubTitle: Catalog.displayName($0)) }
        case .tools:
            return ToolID.tools(forFormats: formats)
                .filter { ToolRegistry.isAvailable($0) }
                .map { WheelTarget(id: "tool:\($0.rawValue)", label: $0.title, symbol: $0.symbol, hubTitle: $0.title) }
        case .actions:
            return ActionID.allCases
                .map { WheelTarget(id: "action:\($0.rawValue)", label: $0.title, symbol: $0.symbol, hubTitle: $0.title) }
        }
    }

    private func choice(for target: WheelTarget) -> WheelChoice? {
        let parts = target.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "convert": return .convert(parts[1])
        case "tool": return ToolID(rawValue: parts[1]).map(WheelChoice.tool)
        case "action": return ActionID(rawValue: parts[1]).map(WheelChoice.action)
        default: return nil
        }
    }

    private func emptyMessage(_ mode: WheelMode, _ targets: [WheelTarget]) -> String? {
        guard targets.isEmpty else { return nil }
        let s = Settings.shared
        switch mode {
        case .tools:
            return "No editing tools for this format. Tap \(s.convertKey.name) to convert or \(s.actionsKey.name) for file actions."
        case .conversions:
            return "No conversions for this format. Tap \(s.actionsKey.name) for file actions."
        case .actions:
            return nil
        }
    }

    private func summary() -> String {
        guard let url = urls.first else { return "" }
        if urls.count > 1 {
            let folders = formats.filter { $0 == "folder" }.count
            return folders > 0 ? "\(urls.count) items" : "\(urls.count) files"
        }
        if formats.first == "folder" { return "Folder" }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isPackageKey])
        if values?.isPackage == true { return Catalog.displayName(formats.first ?? "") }
        guard let bytes = values?.fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Keep the whole wheel on the screen the cursor is on.
    private func clamped(_ p: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.frame else { return p }
        let r = metrics.radius * metrics.scale + 14
        return NSPoint(x: min(max(p.x, frame.minX + r), frame.maxX - r),
                       y: min(max(p.y, frame.minY + r), frame.maxY - r))
    }

    // MARK: Animation

    /// Open: the fruit spins in a quarter turn while growing from 0.45 and fading in (0.3s).
    /// The segments cut in on their own, in WheelView.
    private func bloom() {
        guard let layer = zoomView.layer else { return }
        layer.removeAllAnimations()
        let curve = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.24, 1)

        let grow = CABasicAnimation(keyPath: "transform")
        // Starts turned 28° counter-clockwise (layer space is y-up) and turns into place.
        grow.fromValue = NSValue(caTransform3D: centered(scale: 0.45, degrees: 28))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = 0.3
        grow.timingFunction = curve

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        fade.timingFunction = curve

        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(grow, forKey: "bloom")
        layer.add(fade, forKey: "bloomFade")
    }

    /// Scale and fade the whole fruit around its centre, holding the last frame until hide().
    private func animateZoom(scales: [CGFloat], opacities: [Float], times: [NSNumber], duration: CFTimeInterval,
                             curve: CAMediaTimingFunction) {
        guard let layer = zoomView.layer else { return }
        let size = CAKeyframeAnimation(keyPath: "transform")
        size.values = scales.map { NSValue(caTransform3D: centered(scale: $0)) }
        size.keyTimes = times
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacities
        fade.keyTimes = times
        let group = CAAnimationGroup()
        group.animations = [size, fade]
        group.duration = duration
        group.timingFunction = curve
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "leave")
    }

    /// A transform about the view's centre (AppKit layers anchor at the corner).
    private func centered(scale: CGFloat, degrees: CGFloat = 0) -> CATransform3D {
        let c = CGPoint(x: zoomView.bounds.midX, y: zoomView.bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DRotate(t, degrees * .pi / 180, 0, 0, 1)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -c.x, -c.y, 0)
    }
}

/// Borderless, transparent, never takes focus from the app you're dragging out of.
final class WheelPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives the drag and asks the controller which petal is under it.
final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(sender, in: self) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(sender, in: self) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragLeft()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.hasLitPetal ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender) ?? false
    }
}
