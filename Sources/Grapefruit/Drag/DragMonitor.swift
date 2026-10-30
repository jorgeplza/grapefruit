import AppKit

/// Files being dragged right now.
struct DragSnapshot {
    let urls: [URL]
}

/// Notices file drags anywhere on the Mac and reports modifier-key taps made
/// during them. It needs no special permission: mouse-down events are
/// observable globally, the drag pasteboard is readable by any app, and the
/// modifier state is polled rather than intercepted.
@MainActor
final class DragMonitor {
    /// A wheel should open (or switch) for this drag.
    var onSummon: ((WheelMode, DragSnapshot, NSPoint) -> Void)?
    /// The mouse went up: the drag is over, dropped or not.
    var onDragEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var downChangeCount = 0
    private var snapshot: DragSnapshot?
    private var ignoringThisPress = false
    private var held: Set<ModifierKey> = []
    private var lastPasteboardCheck = Date.distantPast

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(m) }
        // Drags that start in our own windows (the Float shelf) too.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown() }
            return event
        }) { monitors.append(m) }
    }

    var isDraggingFiles: Bool { snapshot != nil }

    private func mouseDown() {
        guard !Settings.shared.paused else { return }
        downChangeCount = NSPasteboard(name: .drag).changeCount
        snapshot = nil
        ignoringThisPress = false
        held = ModifierKey.held(in: NSEvent.modifierFlags)
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let mouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard mouseDown else {
            finish()
            return
        }
        if ignoringThisPress { return }

        guard let snap = snapshot else {
            // A drag has started once its source writes to the drag pasteboard.
            let now = Date()
            guard now.timeIntervalSince(lastPasteboardCheck) > 0.04 else { return }
            lastPasteboardCheck = now
            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            guard changeCount != downChangeCount else { return }
            let urls = Self.fileURLs(on: pasteboard)
            guard !urls.isEmpty else {
                // Text, links or file promises: not ours.
                ignoringThisPress = true
                return
            }
            let started = DragSnapshot(urls: urls)
            snapshot = started
            // A key that is already down when the drag starts opens its wheel straight away.
            let current = ModifierKey.held(in: NSEvent.modifierFlags)
            held = current
            if current.count == 1, let key = current.first, let mode = Settings.shared.mode(for: key) {
                onSummon?(mode, started, NSEvent.mouseLocation)
            }
            return
        }

        let current = ModifierKey.held(in: NSEvent.modifierFlags)
        guard current != held else { return }
        let pressed = current.subtracting(held)
        held = current
        // Exactly one wheel key down, and it was just pressed: open or switch.
        if !pressed.isEmpty, current.count == 1, let key = current.first, let mode = Settings.shared.mode(for: key) {
            onSummon?(mode, snap, NSEvent.mouseLocation)
        }
    }

    private func finish() {
        stopTimer()
        let hadDrag = snapshot != nil
        snapshot = nil
        ignoringThisPress = false
        if hadDrag { onDragEnded?() }
    }

    /// File URLs on a pasteboard, resolving Finder's file-reference URLs.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL], !objects.isEmpty {
            return objects.compactMap { ($0.filePathURL ?? $0 as URL).standardizedFileURL }
        }
        if let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
