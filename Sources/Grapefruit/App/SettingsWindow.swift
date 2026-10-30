import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(onClose: { [weak self] in self?.window?.close() }))
            hosting.sizingOptions = [.preferredContentSize]
            // The hidden title bar would otherwise push the header down by its height.
            hosting.safeAreaRegions = []
            let w = ToolWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.title = "Grapefruit Settings"
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
            w.center()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "Settings", onClose: onClose)

            VStack(alignment: .leading, spacing: 16) {
                section("While dragging a file, tap") {
                    keyRow("Convert", mode: .conversions)
                    keyRow("Tools", mode: .tools)
                    keyRow("File actions", mode: .actions)
                }

                section("Feedback") {
                    Toggle("Click sound when a petal lights up", isOn: $settings.playSounds)
                    Toggle("Haptic tick on the trackpad", isOn: $settings.haptics)
                }

                section("Files") {
                    Toggle("Show results in Finder after saving", isOn: $settings.revealAfterSaving)
                    HStack {
                        Text("Terminal action opens")
                        Spacer()
                        Picker("", selection: $settings.terminal) {
                            ForEach(TerminalChoice.allCases) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                section("General") {
                    Toggle("Open at login", isOn: $settings.launchAtLogin)
                    Toggle("Pause Grapefruit", isOn: $settings.paused)
                }

                section("Engines") {
                    engineRow("ffmpeg", ready: Capabilities.hasFFmpeg, note: "Audio and video. brew install ffmpeg")
                    engineRow("Microsoft PowerPoint", ready: Capabilities.hasPowerPoint || Capabilities.hasKeynote,
                              note: "Opening .ppt and .pptx")
                    engineRow("Microsoft Excel", ready: Capabilities.hasExcel, note: "Opening .xls")
                    engineRow("Pages", ready: Capabilities.hasPages, note: "Reading and writing .pages")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)

            HStack {
                Text("Grapefruit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Grapefruit") { NSApp.terminate(nil) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(width: 400)
        // Same single accent as the wheel's lit petal.
        .tint(WheelPalette.accent)
    }

    /// A titled group: soft fill, no border, like the petals sitting on the wheel's plate.
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }

    private func keyRow(_ title: String, mode: WheelMode) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: binding(for: mode)) {
                ForEach(ModifierKey.allCases) { key in
                    Text(key.glyph).tag(key).help(key.name)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
        }
    }

    private func binding(for mode: WheelMode) -> Binding<ModifierKey> {
        switch mode {
        case .conversions: $settings.convertKey
        case .tools: $settings.toolsKey
        case .actions: $settings.actionsKey
        }
    }

    private func engineRow(_ name: String, ready: Bool, note: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ready ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(name)
            Spacer()
            Text(ready ? "Ready" : note)
                .foregroundStyle(.secondary)
                .font(.system(size: 11.5))
                .lineLimit(1)
        }
    }
}
