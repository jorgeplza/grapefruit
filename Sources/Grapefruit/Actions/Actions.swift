import AppKit

/// What a drop on a petal does.
@MainActor
enum Router {
    static func handle(_ choice: WheelChoice, urls: [URL], anchor: NSPoint) {
        switch choice {
        case .convert(let target):
            JobCenter.shared.run(title: "Converting to \(Catalog.displayName(target))",
                                 steps: Converter.steps(for: urls, to: target), anchor: anchor)
        case .tool(let tool):
            ToolRegistry.open(tool, urls: urls, anchor: anchor)
        case .action(let action):
            Actions.perform(action, urls: urls, anchor: anchor)
        }
    }
}

/// The Control wheel.
@MainActor
enum Actions {
    static func perform(_ action: ActionID, urls: [URL], anchor: NSPoint) {
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop: airDrop(urls, anchor: anchor)
        case .float: FloatShelf.show(urls, near: anchor)
        case .copy: copy(urls, anchor: anchor)
        case .move: move(urls, anchor: anchor)
        case .copyPath: copyPath(urls, anchor: anchor)
        case .openTerminal: openTerminal(urls, anchor: anchor)
        }
    }

    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
    }

    private static func airDrop(_ urls: [URL], anchor: NSPoint) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            JobCenter.shared.failure("AirDrop", detail: "AirDrop isn't available. Turn on Wi-Fi and Bluetooth.", at: anchor)
            return
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    private static func copy(_ urls: [URL], anchor: NSPoint) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        JobCenter.shared.notice(urls.count == 1 ? "Copied" : "Copied \(urls.count) items",
                                detail: urls.count == 1 ? "\(urls[0].lastPathComponent) is ready to paste" : "Ready to paste",
                                at: anchor)
    }

    private static func copyPath(_ urls: [URL], anchor: NSPoint) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        JobCenter.shared.notice(urls.count == 1 ? "Copied path" : "Copied \(urls.count) paths",
                                detail: urls.count == 1 ? urls[0].path : "One per line",
                                at: anchor)
    }

    private static func move(_ urls: [URL], anchor: NSPoint) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = "Move \(describe(urls)) to:"
        panel.directoryURL = urls[0].deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let steps = urls.map { url in
            // Returning the original moves it into the chosen folder, renamed if the name is taken.
            JobStep(name: url.lastPathComponent, destination: folder) { _ in [url] }
        }
        JobCenter.shared.run(title: "Moving to \(folder.lastPathComponent)", steps: steps, anchor: anchor)
    }

    private static func openTerminal(_ urls: [URL], anchor: NSPoint) {
        var folder = urls[0]
        if (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true || Catalog.format(of: folder) != "folder" {
            folder = folder.deletingLastPathComponent()
        }
        let preferred = Settings.shared.terminal == .iterm ? "com.googlecode.iterm2" : "com.apple.Terminal"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            JobCenter.shared.failure("Terminal", detail: "Couldn't find Terminal.", at: anchor)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    JobCenter.shared.failure("Terminal", detail: error.localizedDescription, at: anchor)
                }
            }
        }
    }
}
