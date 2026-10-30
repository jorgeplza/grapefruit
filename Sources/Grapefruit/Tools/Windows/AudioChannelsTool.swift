import Combine
import SwiftUI

/// Convert Audio Channels: pick Mono or Stereo, balance the two sides, preview each output
/// channel, and save "name Mono.ext" or "name Stereo.ext" in the source's format.
struct AudioChannelsTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: ChannelsModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: ChannelsModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            ChannelsContent(model: model, source: model.source, player: model.player)
        } footer: {
            ChannelsFooterNote(model: model, source: model.source)
            // The original has no Reset here, just the action.
            ToolFooter(showsReset: false, primaryTitle: "Apply", primaryEnabled: model.canApply, onPrimary: apply)
        }
        .background(AudioToolKit.CloseHook { model.close() })
    }

    private func apply() {
        let plan = model.plan
        let suffix = plan.output == .mono ? "Mono" : "Stereo"
        model.close()
        let steps = session.urls.map { src in
            JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
                let out = ctx.output(Output.name(src, suffix: suffix))
                try AudioToolKit.Channels.run(src, to: out, plan: plan, ctx: ctx)
                return [out]
            }
        }
        session.run(steps)
    }
}

// MARK: - Model

@MainActor
private final class ChannelsModel: ObservableObject {
    let source: AudioToolKit.Source
    let player: AudioToolKit.Player
    @Published var output = AudioToolKit.Channels.Layout.stereo {
        didSet {
            chosen = true
            // A side's solo has nothing to play once the sides merge into one.
            if output == .mono, player.isPlaying, player.tag != Tag.output { play(Tag.output, from: player.time) }
            push()
        }
    }
    @Published var left = 1.0 { didSet { push() } }
    @Published var right = 1.0 { didSet { push() } }
    private var chosen = false
    private var sourceChannels = 2
    private var solo = AudioToolKit.Channels.Solo.none
    private let mix = AudioToolKit.Locked(AudioToolKit.Channels.Mix())
    private var watch: AnyCancellable?
    private var resumeTag: String?
    private var scrubbing = false

    enum Tag {
        static let left = "left"
        static let right = "right"
        static let output = "output"
    }

    init(url: URL) {
        source = AudioToolKit.Source(url)
        player = AudioToolKit.Player(url: url)
        let box = mix
        let ramp = AudioToolKit.Channels.Ramp()
        player.setProcessor { chunk in AudioToolKit.Channels.apply(box.value, to: chunk, ramp: ramp) }
        watch = source.$info.sink { [weak self] info in
            guard let info else { return }
            MainActor.assumeIsolated {
                // The mono mix depends on how many channels the file has.
                self?.sourceChannels = info.channels
                self?.adopt(info)
                self?.push()
            }
        }
        push()
    }

    /// Starts on the layout the file doesn't have yet: mono files go stereo, everything else mono.
    /// Wider files (5.1) start on stereo, the usual downmix.
    private func adopt(_ info: AudioToolKit.Info) {
        guard !chosen else { return }
        output = info.channels == 2 ? .mono : .stereo
        chosen = false
    }

    var info: AudioToolKit.Info? { source.info }

    var plan: AudioToolKit.Channels.Plan {
        AudioToolKit.Channels.Plan(output: output, left: left, right: right)
    }

    /// True when saving would write the same thing back.
    var unchanged: Bool {
        guard let info else { return false }
        let full = abs(left - 1) < 0.005 && abs(right - 1) < 0.005
        switch output {
        case .stereo: return info.channels == 2 && full
        case .mono: return info.channels == 1 && full
        }
    }

    var canApply: Bool { info != nil && source.failure == nil && !unchanged }

    func isPlaying(_ tag: String) -> Bool { player.isPlaying && player.tag == tag }

    func toggle(_ tag: String) {
        if isPlaying(tag) {
            player.pause()
            return
        }
        let duration = source.duration
        let from: Double
        if player.isPlaying {
            from = player.time
        } else {
            from = duration > 0 && player.parked >= duration - 0.02 ? 0 : player.parked
        }
        play(tag, from: from)
    }

    private func play(_ tag: String, from time: Double) {
        guard source.failure == nil, !player.unavailable else { return }
        switch tag {
        case Tag.left: solo = .left
        case Tag.right: solo = .right
        default: solo = .none
        }
        push()
        player.play(from: time, tag: tag)
    }

    /// Dragging across a lane pauses, moves the playhead, and picks up again on release.
    func scrub(to time: Double) {
        guard source.failure == nil else { return }
        if !scrubbing {
            scrubbing = true
            resumeTag = player.isPlaying ? player.tag : nil
            player.pause()
        }
        player.seek(time)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        if let tag = resumeTag { play(tag, from: player.parked) }
        resumeTag = nil
    }

    func close() {
        player.close()
        source.cancel()
    }

    private func push() {
        var l = left
        var r = right
        if output == .mono {
            (l, r) = AudioToolKit.Channels.monoWeights(left: left, right: right,
                                                       sourceChannels: sourceChannels)
        }
        mix.value = AudioToolKit.Channels.Mix(left: Float(l), right: Float(r),
                                              mono: output == .mono, solo: solo)
    }
}

// MARK: - Views

private struct ChannelsContent: View {
    @ObservedObject var model: ChannelsModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output channel preview")
                Spacer(minLength: 12)
                if let info = source.info {
                    Text("\(info.layoutName) source")
                        .transition(.opacity)
                }
            }
            .font(ToolStyle.label)
            .foregroundStyle(ToolStyle.secondary)
            .frame(height: 15)
            .padding(.top, 4)
            rows
                .frame(height: 100)
                .padding(.top, 12)
            Divider()
                .padding(.top, 12)
            HStack {
                Text("Output")
                    .foregroundStyle(ToolStyle.secondary)
                Spacer()
                Picker("Output", selection: $model.output) {
                    Text("Mono").tag(AudioToolKit.Channels.Layout.mono)
                    Text("Stereo").tag(AudioToolKit.Channels.Layout.stereo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .frame(height: 24)
            .padding(.top, 10)
            VolumeRow(title: "Left volume", value: $model.left)
                .frame(height: 22)
                .padding(.top, 6)
            VolumeRow(title: "Right volume", value: $model.right)
                .frame(height: 22)
                .padding(.top, 5)
            HStack {
                Text("Preview")
                    .foregroundStyle(ToolStyle.secondary)
                Spacer()
                Button {
                    model.toggle(ChannelsModel.Tag.output)
                } label: {
                    Label {
                        Text("Play Output")
                    } icon: {
                        Image(systemName: model.isPlaying(ChannelsModel.Tag.output) ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .disabled(source.failure != nil || player.unavailable)
            }
            .frame(height: 24)
            .padding(.top, 6)
            .padding(.bottom, 18)
            AudioToolKit.SpaceKey { model.toggle(ChannelsModel.Tag.output) }
        }
        .font(ToolStyle.label)
        .padding(.horizontal, 6)
        .disabled(source.failure != nil)
    }

    @ViewBuilder private var rows: some View {
        if let failure = source.failure {
            ZStack {
                RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                    .fill(AudioToolKit.Look.lane)
                AudioToolKit.LaneMessage(text: failure)
            }
        } else {
            ZStack {
                if model.output == .mono {
                    row(letter: "M", tag: ChannelsModel.Tag.output, help: "Play the mono output") { n in
                        mixed(n)
                    }
                    .transition(.opacity)
                } else {
                    row(letter: "L", tag: ChannelsModel.Tag.left, help: "Play the left channel") { n in
                        source.bars(n, channel: 0).map { $0 * Float(model.left) }
                    }
                    .offset(y: -28)
                    .transition(.offset(y: 28).combined(with: .opacity))
                    row(letter: "R", tag: ChannelsModel.Tag.right, help: "Play the right channel") { n in
                        source.bars(n, channel: rightChannel).map { $0 * Float(model.right) }
                    }
                    .offset(y: 28)
                    .transition(.offset(y: -28).combined(with: .opacity))
                }
            }
            .animation(AudioToolKit.Look.spring(reduceMotion), value: model.output)
        }
    }

    /// Mono files feed both sides from their one channel.
    private var rightChannel: Int { (source.levels?.channels ?? 2) > 1 ? 1 : 0 }

    private func mixed(_ n: Int) -> [Float] {
        let l = source.bars(n, channel: 0)
        let r = source.bars(n, channel: rightChannel)
        let w = AudioToolKit.Channels.monoWeights(left: model.left, right: model.right,
                                                  sourceChannels: source.info?.channels ?? 2)
        return zip(l, r).map { $0 * Float(w.left) + $1 * Float(w.right) }
    }

    private func row(letter: String, tag: String, help: String, values: @escaping (Int) -> [Float]) -> some View {
        HStack(spacing: 8) {
            ChannelBadge(letter: letter)
            ChannelLane(source: source, player: player, values: values,
                        onScrub: { model.scrub(to: $0) }, onEnd: { model.endScrub() })
            AudioToolKit.PlainPlayButton(playing: model.isPlaying(tag),
                                         enabled: source.failure == nil && !player.unavailable) {
                model.toggle(tag)
            }
            .help(help)
        }
        .frame(height: 44)
    }
}

/// The round peach "L" / "R" / "M" label in front of a lane.
private struct ChannelBadge: View {
    var letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.mix(with: ToolStyle.orange, by: 0.15).opacity(0.85))
            .frame(width: 24, height: 24)
            .background(Circle().fill(ToolStyle.orange.opacity(0.14)))
            .contentTransition(.opacity)
            .accessibilityHidden(true)
    }
}

/// One output channel: grey bars at the level the volume sets, an orange playhead.
private struct ChannelLane: View {
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    var values: (Int) -> [Float]
    var onScrub: (Double) -> Void
    var onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inner = max(1, width - 4)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                    .fill(AudioToolKit.Look.lane)
                Group {
                    if source.levels == nil {
                        AudioToolKit.LoadingLine()
                    } else {
                        AudioToolKit.Bars(values: values(AudioToolKit.Bars.count(for: inner)),
                                          scale: 1 / Double(max(source.maxPeak, 0.01)), fill: 0.8)
                            .fill(AudioToolKit.Look.grey)
                    }
                }
                .frame(width: inner, height: geo.size.height)
                .offset(x: 3)
                AudioToolKit.Live(active: player.isPlaying) {
                    AudioToolKit.Playhead(color: ToolStyle.orange)
                        .frame(height: geo.size.height)
                        .offset(x: (width - 2) * fraction(player.time))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard source.duration > 0 else { return }
                    onScrub(Double(min(1, max(0, value.location.x / width))) * source.duration)
                }
                .onEnded { _ in onEnd() })
        }
    }

    private func fraction(_ time: Double) -> CGFloat {
        let d = source.duration
        guard d > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / d)))
    }
}

/// "Left volume  ----o----  100%"
private struct VolumeRow: View {
    var title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: 0...1) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// Says why Apply is off, in the footer next to it.
private struct ChannelsFooterNote: View {
    @ObservedObject var model: ChannelsModel
    @ObservedObject var source: AudioToolKit.Source

    var body: some View {
        Group {
            if source.failure != nil {
                Text("Can't convert this file")
            } else if model.unchanged {
                Text(model.output == .mono ? "Already mono" : "Already stereo")
            }
        }
        .font(ToolStyle.label)
        .foregroundStyle(ToolStyle.secondary)
        .lineLimit(1)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: model.unchanged)
    }
}

// MARK: - Processing

extension AudioToolKit {
    enum Channels {
        enum Layout: Hashable { case mono, stereo }
        enum Solo { case none, left, right }

        /// What the window asked for: the output layout and a volume per side, 0...1.
        struct Plan {
            var output: Layout
            var left: Double
            var right: Double
        }

        /// How much of each side goes into a mono mix. At full volume both sides count half,
        /// the usual downmix. Turning one side down hands its share to the other, so a
        /// recording with sound only on the left comes out at full level once the right is
        /// off, and the louder slider sets the overall level. A mono file feeds both sides
        /// from one channel, so there each slider simply counts half.
        static func monoWeights(left: Double, right: Double, sourceChannels: Int) -> (left: Double, right: Double) {
            let l = min(1, max(0, left))
            let r = min(1, max(0, right))
            guard sourceChannels != 1 else { return (l / 2, r / 2) }
            let sum = l + r
            guard sum > 0 else { return (0, 0) }
            let scale = max(l, r) / sum
            return (l * scale, r * scale)
        }

        /// What the preview applies on the audio thread.
        struct Mix {
            var left: Float = 1
            var right: Float = 1
            var mono = false
            var solo = Solo.none
        }

        /// The volumes the last chunk ended on. Only touched on the player's queue.
        final class Ramp: @unchecked Sendable {
            var left: Float = 1
            var right: Float = 1
        }

        /// Volumes ramp across the chunk, so dragging a slider while listening never clicks.
        /// For mono the volumes arrive as `monoWeights`, the same mix as the saved file.
        static func apply(_ m: Mix, to c: Chunk, ramp: Ramp) {
            let n = c.frames
            guard n > 0 else { return }
            var gl = ramp.left
            var gr = ramp.right
            let dl = (m.left - gl) / Float(n)
            let dr = (m.right - gr) / Float(n)
            ramp.left = m.left
            ramp.right = m.right
            for i in 0..<n {
                let l = c.left[i] * gl
                let r = c.right[i] * gr
                gl += dl
                gr += dr
                switch m.solo {
                case .left:
                    c.left[i] = l
                    c.right[i] = l
                case .right:
                    c.left[i] = r
                    c.right[i] = r
                case .none:
                    if m.mono {
                        let mid = l + r
                        c.left[i] = mid
                        c.right[i] = mid
                    } else {
                        c.left[i] = l
                        c.right[i] = r
                    }
                }
            }
        }

        /// The pan filter for a plan. Files wider than stereo are mixed down to stereo first,
        /// mono files feed both sides.
        static func filter(_ plan: Plan, channels: Int) -> String {
            func g(_ v: Double) -> String { String(format: "%.4f", min(1, max(0, v))) }
            var chain: [String] = []
            if channels > 2 { chain.append("aformat=channel_layouts=stereo") }
            let leftIn = "c0"
            let rightIn = channels == 1 ? "c0" : "c1"
            switch plan.output {
            case .stereo:
                chain.append("pan=stereo|c0=\(g(plan.left))*\(leftIn)|c1=\(g(plan.right))*\(rightIn)")
            case .mono:
                let w = monoWeights(left: plan.left, right: plan.right, sourceChannels: channels)
                if channels == 1 {
                    chain.append("pan=mono|c0=\(g(w.left + w.right))*c0")
                } else {
                    chain.append("pan=mono|c0=\(g(w.left))*c0+\(g(w.right))*c1")
                }
            }
            return chain.joined(separator: ",")
        }

        static func run(_ src: URL, to out: URL, plan: Plan, ctx: JobContext) throws {
            let info = try AudioToolKit.probe(src, ctx: ctx)
            let chain = filter(plan, channels: info.channels) + "," + AudioToolKit.finishingFilter(for: info, ext: out.pathExtension)
            try AudioToolKit.render(src, info: info, filter: chain, to: out, ctx: ctx)
        }
    }
}
