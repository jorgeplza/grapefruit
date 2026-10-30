import AppKit
import Combine

/// Menu bar item, and the wiring between drag detection, the wheel and the work it starts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let wheel = WheelController()
    private var pauseItem: NSMenuItem!
    private var hintItems: [NSMenuItem] = []
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpMainMenu()

        monitor.onSummon = { [weak self] mode, snapshot, point in
            self?.wheel.show(mode: mode, urls: snapshot.urls, at: point)
        }
        monitor.onDragEnded = { [weak self] in
            self?.wheel.dragEnded()
        }
        wheel.onChoose = { choice, urls, anchor in
            Router.handle(choice, urls: urls, anchor: anchor)
        }
        monitor.start()
        Capabilities.warmUp()

        Settings.shared.$paused
            .receive(on: RunLoop.main)
            .sink { [weak self] paused in self?.statusItem.button?.appearsDisabled = paused }
            .store(in: &cancellables)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    // MARK: Menu bar

    /// A menu bar app shows no menus, but text fields still need ⌘C, ⌘V, ⌘Z and friends, and windows need ⌘W.
    /// Those shortcuts come from the main menu, so the app keeps one that never shows.
    private func setUpMainMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        submenu("Grapefruit", [item("Quit Grapefruit", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.toolTip = "Grapefruit"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        for mode in WheelMode.allCases {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            hintItems.append(item)
            menu.addItem(item)
            _ = mode
        }
        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Grapefruit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = Settings.shared
        let lines: [(WheelMode, String)] = [(.conversions, "Convert"), (.tools, "Tools"), (.actions, "File actions")]
        for (item, line) in zip(hintItems, lines) {
            let key = s.key(for: line.0)
            item.attributedTitle = Self.hint(glyph: key.glyph, text: "Tap \(key.name) while dragging: \(line.1)")
        }
        pauseItem.title = s.paused ? "Resume" : "Pause"
    }

    private static func hint(glyph: String, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: glyph + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    @objc private func togglePause() {
        Settings.shared.paused.toggle()
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The menu bar glyph: a rind ring around six
/// segments with the top one lit. Drawn as a template image so macOS can recolour it.
enum MenuBarIcon {
    static func make() -> NSImage {
        let metrics = WheelMetrics(inner: 1.8, outer: 5.5, gap: 1.15, corner: 0.9)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(.black)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 15, height: 15))
            for i in 0..<6 {
                // Unlit segments at 34%, so the lit one reads at a glance.
                ctx.setFillColor(NSColor.black.withAlphaComponent(i == 0 ? 1 : 0.34).cgColor)
                ctx.addPath(WheelGeometry.petalPath(index: i, count: 6, center: CGPoint(x: 9, y: 9), metrics: metrics))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
