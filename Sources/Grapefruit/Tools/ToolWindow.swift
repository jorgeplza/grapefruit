import AppKit
import SwiftUI

// Tool windows follow the original: a glass × at top left, a centered bold title,
// hairlines under the title and above the footer, native controls in between,
// Reset on the left of the footer and the main action on the right.
enum ToolStyle {
    static let orange = Color(red: 243 / 255, green: 91 / 255, blue: 40 / 255)
    static let nsOrange = NSColor(srgbRed: 243 / 255, green: 91 / 255, blue: 40 / 255, alpha: 1)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let label = Font.system(size: 12)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let mono = Font.system(size: 11.5).monospacedDigit()
    static let previewBackground = Color.black.opacity(0.045)
    static let contentPadding: CGFloat = 12
}

/// The frame every tool window shares.
struct ToolChrome<Content: View, Footer: View>: View {
    let title: String
    var width: CGFloat = 400
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: title, onClose: onClose)
            Divider()
            content
                .padding(ToolStyle.contentPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            HStack(spacing: 8) { footer }
                .controlSize(.regular)
                .padding(.horizontal, 14)
                .frame(height: 50)
        }
        .frame(width: width)
        .tint(ToolStyle.orange)
    }
}

/// Reset on the left, the tool's action on the right.
struct ToolFooter: View {
    var resetEnabled: Bool = true
    var showsReset: Bool = true
    var onReset: () -> Void = {}
    var primaryTitle: String
    var primaryEnabled: Bool = true
    var onPrimary: () -> Void

    var body: some View {
        if showsReset {
            Button("Reset", action: onReset)
                .disabled(!resetEnabled)
        }
        Spacer()
        Button(primaryTitle, action: onPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryEnabled)
    }
}

/// Title bar shared by tool windows and Settings: glass × on the left, centered title.
/// The × sits 10pt from the top and left so it follows the window's rounded corner.
struct WindowHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 48)
            HStack {
                GlassCloseButton(action: onClose)
                Spacer()
            }
            .padding(.leading, 10)
        }
        .frame(height: 48)
    }
}

/// The round close button in the title bar: one layer of glass, no fill underneath.
struct GlassCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

/// A small grey caption row: text on the left, optional value on the right.
struct ToolCaption: View {
    var text: String
    var value: String? = nil

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            if let value { Text(value).monospacedDigit() }
        }
        .font(ToolStyle.label)
        .foregroundStyle(ToolStyle.secondary)
    }
}

/// A labelled slider row: "Padding ——o—— 160 px".
struct ToolSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(ToolStyle.label)
                .frame(width: 74, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(format(value))
                .font(ToolStyle.mono)
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// Hosts a tool's SwiftUI view in a floating window near where the wheel was.
@MainActor
final class ToolWindowController: NSObject, NSWindowDelegate {
    private static var open: [ToolWindowController] = []
    private let window: NSWindow
    private let session: ToolSession

    static func present(session: ToolSession, content: AnyView) {
        let controller = ToolWindowController(session: session, content: content)
        open.append(controller)
        controller.show()
    }

    private init(session: ToolSession, content: AnyView) {
        self.session = session
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        // The hidden title bar would otherwise push the header down by its height.
        hosting.safeAreaRegions = []
        window = ToolWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = session.tool.name
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.animationBehavior = .utilityWindow
        super.init()
        window.delegate = self
        session.close = { [weak self] in self?.window.close() }
    }

    private func show() {
        window.layoutIfNeeded()
        let size = window.frame.size
        let anchor = session.anchor
        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 12), visible.maxX - frame.width - 12)
            frame.origin.y = min(max(frame.minY, visible.minY + 12), visible.maxY - frame.height - 12)
        }
        window.setFrame(frame, display: false)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        session.close = {}
        Self.open.removeAll { $0 === self }
    }
}

final class ToolWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
