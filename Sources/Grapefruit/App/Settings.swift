import AppKit
import Combine
import ServiceManagement

/// A modifier key that can summon a wheel.
enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        }
    }

    var glyph: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        }
    }

    var name: String {
        switch self {
        case .shift: "Shift"
        case .command: "Command"
        case .control: "Control"
        case .option: "Option"
        }
    }

    static func held(in flags: NSEvent.ModifierFlags) -> Set<ModifierKey> {
        Set(allCases.filter { flags.contains($0.flag) })
    }
}

enum TerminalChoice: String, CaseIterable, Identifiable {
    case terminal, iterm
    var id: String { rawValue }
    var name: String { self == .terminal ? "Terminal" : "iTerm2" }
}

/// User preferences, stored in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var convertKey: ModifierKey { didSet { keyChanged(.conversions, old: oldValue) } }
    @Published var toolsKey: ModifierKey { didSet { keyChanged(.tools, old: oldValue) } }
    @Published var actionsKey: ModifierKey { didSet { keyChanged(.actions, old: oldValue) } }
    @Published var playSounds: Bool { didSet { save(playSounds, "playSounds") } }
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var terminal: TerminalChoice { didSet { save(terminal.rawValue, "terminal") } }
    @Published var paused: Bool { didSet { save(paused, "paused") } }
    @Published var revealAfterSaving: Bool { didSet { save(revealAfterSaving, "revealAfterSaving") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Grapefruit: login item change failed: \(error.localizedDescription)")
            }
        }
    }

    private var isDeduping = false

    private init() {
        convertKey = ModifierKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = ModifierKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = ModifierKey(rawValue: defaults.string(forKey: "actionsKey") ?? "") ?? .control
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        terminal = TerminalChoice(rawValue: defaults.string(forKey: "terminal") ?? "") ?? .terminal
        paused = defaults.object(forKey: "paused") as? Bool ?? false
        revealAfterSaving = defaults.object(forKey: "revealAfterSaving") as? Bool ?? false
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func key(for mode: WheelMode) -> ModifierKey {
        switch mode {
        case .conversions: convertKey
        case .tools: toolsKey
        case .actions: actionsKey
        }
    }

    func mode(for key: ModifierKey) -> WheelMode? {
        WheelMode.allCases.first { self.key(for: $0) == key }
    }

    /// Two wheels can't share a key: picking a taken key swaps the two.
    private func keyChanged(_ mode: WheelMode, old: ModifierKey) {
        save(convertKey.rawValue, "convertKey")
        save(toolsKey.rawValue, "toolsKey")
        save(actionsKey.rawValue, "actionsKey")
        guard !isDeduping else { return }
        isDeduping = true
        defer { isDeduping = false }
        let new = key(for: mode)
        for other in WheelMode.allCases where other != mode && key(for: other) == new {
            switch other {
            case .conversions: convertKey = old
            case .tools: toolsKey = old
            case .actions: actionsKey = old
            }
        }
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
