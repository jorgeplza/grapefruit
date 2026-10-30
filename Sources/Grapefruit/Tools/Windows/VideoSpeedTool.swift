import SwiftUI

private typealias Kit = VideoToolKit

/// Change Video Speed: preview a slower or faster video while the sound keeps its pitch.
/// Saves "name Speed 2x.ext", "name Speed 0.5x.ext"...
struct VideoSpeedTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var player: Kit.Player
    @State private var link = Kit.WindowLink()
    /// Slider position: one unit per labelled stop, 2 is 1×.
    @State private var position = 2.0
    @State private var detent: Int? = 2
    private let previewHeight: CGFloat

    private static let labels = ["0.25×", "0.5×", "1×", "1.5×", "2×", "4×"]
    /// How close (in stops) the slider has to come to a stop to settle on it.
    private static let magnet = 0.06

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _player = State(initialValue: Kit.Player(url: session.url))
        previewHeight = Kit.previewHeight(414, rest: 235, anchor: session.anchor)
    }

    private var speed: Double { Kit.speed(at: position) }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                Kit.PreviewBox(player: player, height: previewHeight) { _ in EmptyView() }
                HStack(alignment: .firstTextBaseline) {
                    Text("Playback speed")
                        .font(Kit.Look.label)
                    Spacer()
                    Text("\(Kit.trimmed(speed))×")
                        .font(Kit.Look.value)
                        .monospacedDigit()
                }
                .padding(.horizontal, Kit.Look.inset)
                .padding(.top, 16)
                Slider(value: $position, in: 0...5) {
                    Text("Playback speed")
                } ticks: {
                    SliderTickContentForEach([0.0, 1, 2, 3, 4, 5], id: \.self) { SliderTick($0) }
                }
                .labelsHidden()
                .padding(.horizontal, Kit.Look.inset)
                .padding(.top, 8)
                tickLabels
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 2)
                Kit.Transport(player: player, showsSteps: false, speed: speed)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 8)
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Apply",
                       primaryEnabled: player.isReady && abs(speed - 1) > 0.001, onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) { player.stop() })
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: position) { _, value in settle(value) }
    }

    /// "0.25×" to "4×" under the slider's tick marks. Clicking one picks it.
    private var tickLabels: some View {
        GeometryReader { geo in
            let inset = Kit.sliderTickInset
            let span = geo.size.width - inset * 2
            ForEach(0..<Self.labels.count, id: \.self) { i in
                let selected = abs(position - Double(i)) < 0.001
                Button {
                    position = Double(i)
                } label: {
                    Text(Self.labels[i])
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : ToolStyle.secondary)
                        .fixedSize()
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: inset + span * CGFloat(i) / CGFloat(Self.labels.count - 1), y: 8)
            }
        }
        .frame(height: 16)
    }

    /// Stops are slightly magnetic, with a tap when the slider lands on one.
    private func settle(_ value: Double) {
        let nearest = value.rounded()
        if abs(value - nearest) < Self.magnet, value != nearest {
            position = nearest
            return
        }
        let stop = value == nearest ? Int(nearest) : nil
        if stop != detent {
            detent = stop
            if stop != nil { Kit.haptic() }
        }
        player.rate = Float(speed)
    }

    private func apply() {
        let src = session.url
        let factor = speed
        let name = Output.name(src, suffix: "\(session.tool.outputSuffix) \(Kit.trimmed(factor))x")
        player.stop()
        let step = JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
            let out = ctx.output(name)
            try VideoToolKit.changeSpeed(src, factor: factor, to: out, ctx: ctx)
            return [out]
        }
        session.run([step])
    }
}
