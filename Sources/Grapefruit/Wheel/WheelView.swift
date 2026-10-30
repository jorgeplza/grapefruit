import SwiftUI

/// One petal on the wheel.
struct WheelTarget: Identifiable, Equatable {
    let id: String
    let label: String          // petal text
    let symbol: String?        // tools and actions show an icon above the text
    let hubTitle: String       // what the core says when this petal is lit
}

@MainActor
final class WheelModel: ObservableObject {
    @Published var targets: [WheelTarget] = []
    @Published var highlighted: Int?
    @Published var mode: WheelMode = .conversions
    @Published var hubSummary = ""
    @Published var emptyMessage: String?
    /// Bumped on every open and switch so the segments cut in again.
    @Published var generation = 0
    /// The old segments sinking away during a switch.
    @Published var leaving = false
    /// The segment that was dropped on, popping out.
    @Published var popped: Int?
}

/// One Liquid Glass plate is the wheel's base; petals and the core are soft light shapes
/// sitting on it (only one glass layer, glass on glass glitches and turns muddy).
/// The only colour is the Mac's accent colour, which lights the petal under the drag.
enum WheelPalette {
    static let accent = Color(nsColor: .controlAccentColor)
    static let litInk = Color.white          // label on the lit petal
    static let ink = Color.primary           // petal labels
    static let hubInk = Color.secondary      // file size in the core
    static let petal = Color(light: .white.withAlphaComponent(0.42), dark: .white.withAlphaComponent(0.09))
    static let petalEdge = Color(light: .white.withAlphaComponent(0.75), dark: .white.withAlphaComponent(0.14))
    static let hub = Color(light: .white.withAlphaComponent(0.72), dark: .white.withAlphaComponent(0.14))
    static let shadow = Color.black.opacity(0.06)   // lifts petals and core off the plate
}

extension Color {
    /// A colour that follows light and dark mode.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Wheel motion timings.
enum WheelMotion {
    /// A segment cutting in: cubic-bezier(.2, 1.25, .4, 1), 0.36s, 16ms apart.
    static func cutIn(_ index: Int) -> Animation {
        .timingCurve(0.2, 1.25, 0.4, 1, duration: 0.36).delay(Double(index) * 0.016)
    }
    static let sink = Animation.easeIn(duration: 0.12)
    /// Lit segment sliding out: a quick spring, barely any overshoot.
    static let lift = Animation.spring(response: 0.26, dampingFraction: 0.82)
    static let tint = Animation.easeInOut(duration: 0.16)
    static let pop = Animation.easeOut(duration: 0.16)
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    var metrics: WheelMetrics = .standard

    var body: some View {
        let size = metrics.canvas
        let center = CGPoint(x: size / 2, y: size / 2)
        ZStack {
            if let message = model.emptyMessage {
                EmptyWheelCard(message: message)
                    .transition(.opacity)
            } else {
                ZStack {
                    // The base: one glass plate the petals sit in.
                    Color.clear
                        .frame(width: metrics.pith * 2, height: metrics.pith * 2)
                        .glassEffect(.regular, in: .circle)

                    ZStack {
                        ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                            PetalView(index: index, count: model.targets.count, target: target,
                                      lit: model.highlighted == index, popped: model.popped == index,
                                      leaving: model.leaving, showsIcon: model.mode != .conversions,
                                      metrics: metrics, center: center)
                        }
                    }
                    .id(model.generation)

                    Hub(model: model, metrics: metrics)
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(metrics.scale)
    }
}

/// A segment outline.
struct PetalShape: Shape {
    var index: Int
    var count: Int
    var metrics: WheelMetrics

    func path(in rect: CGRect) -> Path {
        Path(WheelGeometry.petalPath(index: index, count: count,
                                     center: CGPoint(x: rect.midX, y: rect.midY), metrics: metrics))
    }
}

struct PetalView: View {
    let index: Int
    let count: Int
    let target: WheelTarget
    let lit: Bool
    let popped: Bool
    let leaving: Bool
    let showsIcon: Bool
    let metrics: WheelMetrics
    let center: CGPoint

    @State private var shown = false

    var body: some View {
        let size = metrics.canvas
        let shape = PetalShape(index: index, count: count, metrics: metrics)
        let slide = popped ? metrics.pop : 0
        let on = lit || popped

        ZStack {
            shape.fill(WheelPalette.petal)
                .shadow(color: WheelPalette.shadow, radius: 3, x: 0, y: 1)
            // The lit petal fills with the accent colour.
            shape.fill(WheelPalette.accent)
                .opacity(on ? 1 : 0)
            shape.stroke(WheelPalette.petalEdge, lineWidth: 1)
                .opacity(on ? 0 : 1)
            label
                .foregroundStyle(on ? WheelPalette.litInk : WheelPalette.ink)
                .position(WheelGeometry.labelPoint(index: index, count: count, center: center, metrics: metrics))
        }
        .animation(WheelMotion.tint, value: on)
        .frame(width: size, height: size)
        // Cut in from the core, sink away on a switch.
        .scaleEffect(leaving ? 0.7 : shown ? 1 : 0.55)
        .rotationEffect(.degrees(shown || leaving ? 0 : -16))
        .opacity(leaving || !shown ? 0 : 1)
        .animation(WheelMotion.sink, value: leaving)
        // Hover only recolours; the segment slides out of the pith on drop.
        .offset(WheelGeometry.outward(index: index, count: count, by: slide))
        .animation(popped ? WheelMotion.pop : WheelMotion.lift, value: slide)
        .onAppear {
            withAnimation(WheelMotion.cutIn(index)) { shown = true }
        }
    }

    @ViewBuilder private var label: some View {
        if showsIcon, let symbol = target.symbol {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(target.label)
                    .font(.system(size: 9.4, weight: .semibold))
                    .tracking(0.66)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            Text(target.label)
                .font(.system(size: 15.5, weight: .semibold))
                .tracking(0.31)
                .fixedSize()
        }
    }
}

/// The core: the wheel's name on top, the file size below, or the lit segment's name.
struct Hub: View {
    @ObservedObject var model: WheelModel
    let metrics: WheelMetrics

    var body: some View {
        let lit = model.highlighted.flatMap { $0 < model.targets.count ? model.targets[$0] : nil }
        ZStack {
            Circle()
                .fill(WheelPalette.hub)
                .shadow(color: WheelPalette.shadow, radius: 6, x: 0, y: 2)
                .frame(width: metrics.hub * 2, height: metrics.hub * 2)
            Text(model.mode.wheelName)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.08)
                .foregroundStyle(WheelPalette.accent)
                .offset(y: -15)
            value(lit)
                .offset(y: 7)
        }
    }

    @ViewBuilder private func value(_ lit: WheelTarget?) -> some View {
        if let lit {
            let big = model.mode == .conversions
            Text(big ? lit.hubTitle : Self.balanced(lit.hubTitle))
                .font(.system(size: big ? 17 : 11, weight: .bold))
                .multilineTextAlignment(.center)
                .lineSpacing(big ? 0 : -0.5)
                .foregroundStyle(WheelPalette.accent)
                .fixedSize()
        } else {
            Text(model.hubSummary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WheelPalette.hubInk)
                .fixedSize()
        }
    }

    /// Long names break into two lines of about the same length.
    static func balanced(_ s: String) -> String {
        let words = s.split(separator: " ").map(String.init)
        guard s.count > 10, words.count > 1 else { return s }
        var best = 1
        var diff = Int.max
        for k in 1..<words.count {
            let d = abs(words[..<k].joined(separator: " ").count - words[k...].joined(separator: " ").count)
            if d < diff { diff = d; best = k }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }
}

extension WheelMode {
    /// Shown at the top of the core.
    var wheelName: String {
        switch self {
        case .conversions: "CONVERT"
        case .tools: "TOOLS"
        case .actions: "ACTIONS"
        }
    }
}

/// Shown instead of segments when the dragged file has nothing for this key: one glass card.
struct EmptyWheelCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(WheelPalette.ink)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.vertical, 22)
            .padding(.horizontal, 24)
            .frame(width: 250)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
