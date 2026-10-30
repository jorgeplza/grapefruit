import AppKit
import SwiftUI

// Measured from the original's progress card: 16pt corners, a grey × disc,
// a semibold grey title, the file and percent below, a thin orange bar.
enum ToastStyle {
    static let width: CGFloat = 268
    static let corner: CGFloat = 16
    static let margin: CGFloat = 28          // room for the shadow inside the panel
    static let card = Color(white: 0.985)
    static let border = Color.black.opacity(0.075)
    static let title = Color(white: 0.31)
    static let detail = Color(white: 0.52)
    static let closeDisc = Color(white: 0.915)
    static let closeGlyph = Color(white: 0.36)
    static let orange = Color(red: 243 / 255, green: 91 / 255, blue: 40 / 255)
    static let track = Color.black.opacity(0.06)
    static let failure = Color(red: 0.80, green: 0.27, blue: 0.21)
}

/// Shows one floating card per job near where the wheel was.
@MainActor
final class ToastController {
    private var panels: [UUID: ToastPanel] = [:]
    private var order: [UUID] = []

    func show(_ job: Job, at anchor: NSPoint) {
        let view = ToastView(job: job,
                             onClose: { [weak self, weak job] in
                                 guard let job else { return }
                                 if job.phase == .running { job.onCancel?() }
                                 self?.dismiss(job, after: 0)
                             },
                             onOpen: { [weak self, weak job] in
                                 guard let job else { return }
                                 JobCenter.shared.reveal(job)
                                 self?.dismiss(job, after: 0)
                             })
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        let panel = ToastPanel(size: size)
        panel.contentView = hosting

        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2,
                           width: size.width, height: size.height)
        frame = placed(frame)
        panel.setFrame(frame, display: false)
        panels[job.id] = panel
        order.append(job.id)

        // Pop in: a small scale-up and fade, quick enough to never feel in the way.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if let layer = hosting.layer {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.94
            grow.toValue = 1
            grow.duration = 0.22
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: hosting.bounds.midX, y: hosting.bounds.midY)
            layer.add(grow, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    /// Keep the card on screen and out of the way of cards already showing.
    private func placed(_ proposed: NSRect) -> NSRect {
        var frame = proposed
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: proposed.midX, y: proposed.midY)) } ?? NSScreen.main
        let others = order.compactMap { panels[$0]?.frame }
        var attempts = 0
        while others.contains(where: { $0.insetBy(dx: ToastStyle.margin, dy: ToastStyle.margin)
            .intersects(frame.insetBy(dx: ToastStyle.margin, dy: ToastStyle.margin)) }) && attempts < 8 {
            frame.origin.y -= frame.height - ToastStyle.margin * 2 + 10
            attempts += 1
        }
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX - ToastStyle.margin + 8), visible.maxX - frame.width + ToastStyle.margin - 8)
            frame.origin.y = min(max(frame.minY, visible.minY - ToastStyle.margin + 8), visible.maxY - frame.height + ToastStyle.margin - 8)
        }
        return frame
    }

    func dismiss(_ job: Job, after delay: TimeInterval) {
        let id = job.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panels[id] else { return }
                // A card the pointer is resting on stays until it leaves.
                if delay > 0, panel.isHovered {
                    self.dismiss(job, after: 0.8)
                    return
                }
                self.panels[id] = nil
                self.order.removeAll { $0 == id }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { panel.orderOut(nil) }
                })
            }
        }
    }
}

final class ToastPanel: NSPanel {
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

    override var contentView: NSView? {
        didSet {
            guard let view = contentView else { return }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            view.addTrackingArea(area)
            tracking = area
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

struct ToastView: View {
    @ObservedObject var job: Job
    var onClose: () -> Void
    var onOpen: () -> Void
    @State private var hoveringCard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ToastCloseButton(action: onClose)
                Text(job.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ToastStyle.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                Text(job.detail)
                    .lineLimit(job.phase == .failed ? 3 : 1)
                    .truncationMode(.middle)
                    .foregroundStyle(job.phase == .failed ? ToastStyle.failure : ToastStyle.detail)
                if let percent = job.percentText {
                    Text(" · " + percent)
                        .monospacedDigit()
                        .foregroundStyle(ToastStyle.detail)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .padding(.top, 9)
            .padding(.leading, 3)
            .contentTransition(.numericText())

            if !job.isNotice || job.phase == .failed {
                ToastBar(value: job.progress, failed: job.phase == .failed)
                    .frame(height: 4)
                    .padding(.top, 11)
                    .padding(.horizontal, 3)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, job.isNotice && job.phase != .failed ? 14 : 13)
        .frame(width: ToastStyle.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ToastStyle.corner, style: .continuous)
                .fill(ToastStyle.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ToastStyle.corner, style: .continuous)
                .strokeBorder(ToastStyle.border, lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.11), radius: 18, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: ToastStyle.corner, style: .continuous))
        .onTapGesture {
            if job.phase == .finished, !job.outputs.isEmpty { onOpen() }
        }
        .onHover { hoveringCard = $0 }
        .help(job.phase == .finished && !job.outputs.isEmpty ? "Show in Finder" : "")
        .padding(ToastStyle.margin)
        .animation(.easeOut(duration: 0.2), value: job.phase)
    }
}

struct ToastCloseButton: View {
    var action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? Color(white: 0.87) : ToastStyle.closeDisc)
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(ToastStyle.closeGlyph)
            }
            .frame(width: 22, height: 22)
            .scaleEffect(pressed ? 0.9 : 1)
        }
        .buttonStyle(PressRecordingStyle(pressed: $pressed))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
    }
}

/// A plain button style that reports its pressed state.
struct PressRecordingStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, new in pressed = new }
    }
}

struct ToastBar: View {
    var value: Double
    var failed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ToastStyle.track)
                Capsule()
                    .fill(failed ? ToastStyle.failure.opacity(0.85) : ToastStyle.orange)
                    .frame(width: max(4, geo.size.width * (failed ? 1 : value)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: value)
    }
}
