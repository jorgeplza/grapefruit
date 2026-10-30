import Combine
import SwiftUI

/// Trim Audio: drag the ends of the waveform (or type the times), optionally snap the ends to
/// where the sound starts and stops, listen to the selection, and save "name Trimmed.ext".
struct TrimAudioTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: TrimModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: TrimModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            TrimContent(model: model, source: model.source, player: model.player)
        } footer: {
            // The original has no Reset here, just the action.
            ToolFooter(showsReset: false, primaryTitle: "Apply", primaryEnabled: model.canApply, onPrimary: apply)
        }
        .background(AudioToolKit.CloseHook { model.close() })
    }

    private func apply() {
        let start = model.start
        let end = model.endValue
        model.close()
        session.runEach { src, out, ctx in
            try AudioToolKit.Trimmer.run(src, to: out, start: start, end: end, ctx: ctx)
        }
    }
}

// MARK: - Model

private enum TrimEdge { case start, end }

@MainActor
private final class TrimModel: ObservableObject {
    /// What "Trim silent ends automatically" can do for this file.
    enum Sound: Equatable {
        case loading
        case bounds(ClosedRange<Double>)
        case nothingToTrim
        case silent
        case unreadable
    }

    let source: AudioToolKit.Source
    let player: AudioToolKit.Player
    @Published private(set) var start: Double = 0
    /// Nil means the end of the file, so the exact length can arrive after decoding.
    @Published private(set) var endValue: Double?
    @Published private(set) var autoTrim = false
    @Published private(set) var sound = Sound.loading
    /// The range from before "Trim silent ends" was ticked, to put back when it's unticked.
    private var manual: (start: Double, end: Double?) = (0, nil)
    private var watch: AnyCancellable?

    init(url: URL) {
        source = AudioToolKit.Source(url)
        player = AudioToolKit.Player(url: url)
        watch = source.$phase.sink { [weak self] phase in
            // Runs as the phase changes, when the levels are already in place.
            MainActor.assumeIsolated { self?.update(for: phase) }
        }
    }

    var duration: Double { source.duration }
    var end: Double { min(endValue ?? duration, duration) }
    var length: Double { max(0, end - start) }
    var minLength: Double { min(0.05, duration) }
    var canEdit: Bool { source.info != nil && source.failure == nil && duration > 0 }
    var isWholeFile: Bool { start <= 0.005 && end >= duration - 0.005 }
    var canApply: Bool { canEdit && !isWholeFile && length >= minLength * 0.99 }

    /// Seconds where the playhead shows: while playing, or paused partway through.
    var playheadVisible: Bool {
        player.isPlaying || (player.parked > start + 0.01 && player.parked < end - 0.01)
    }

    func set(_ edge: TrimEdge, _ value: Double) {
        guard canEdit else { return }
        switch edge {
        case .start:
            start = min(max(0, value), end - minLength)
        case .end:
            let v = min(max(start + minLength, value), duration)
            endValue = v >= duration - 0.0005 ? nil : v
        }
        autoTrim = false
        if !player.isPlaying, player.parked < start || player.parked > end { player.seek(start) }
    }

    func setAutoTrim(_ on: Bool) {
        guard case .bounds(let b) = sound else { return }
        if on {
            manual = (start, endValue)
            start = b.lowerBound
            endValue = b.upperBound >= duration - 0.0005 ? nil : b.upperBound
        } else {
            start = manual.start
            endValue = manual.end
        }
        autoTrim = on
        if player.isPlaying { play(from: start) } else { player.seek(start) }
    }

    func togglePlay() {
        guard canEdit, !player.unavailable else { return }
        if player.isPlaying {
            player.pause()
            return
        }
        let p = player.parked
        play(from: p > start + 0.01 && p < end - 0.02 ? p : start)
    }

    func play(from time: Double) {
        player.play(from: time, to: endValue == nil ? nil : end, rewindTo: start)
    }

    /// Where a dragged edge should land, pulled onto the found sound edge when it's close.
    func snapped(_ edge: TrimEdge, _ value: Double, tolerance: Double) -> (value: Double, snapped: Bool) {
        if case .bounds(let b) = sound {
            let target = edge == .start ? b.lowerBound : b.upperBound
            if abs(value - target) <= tolerance { return (target, true) }
        }
        let limit = edge == .start ? 0 : duration
        if abs(value - limit) <= tolerance { return (limit, true) }
        return (value, false)
    }

    func close() {
        player.close()
        source.cancel()
    }

    private func update(for phase: AudioToolKit.Source.Phase) {
        switch phase {
        case .loading:
            sound = .loading
        case .failed:
            sound = .unreadable
        case .ready:
            guard let levels = source.levels else { return }
            guard let b = levels.soundBounds() else {
                sound = .silent
                return
            }
            let total = levels.duration
            sound = b.lowerBound <= 0.01 && b.upperBound >= total - 0.01 ? .nothingToTrim : .bounds(b)
        }
    }
}

// MARK: - Views

private struct TrimContent: View {
    @ObservedObject var model: TrimModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolCaption(text: "Drag the ends to trim", value: model.canEdit ? source.clock(model.length) + " selected" : nil)
                .frame(height: 15)
                .padding(.bottom, 6)
            TrimLane(model: model, source: source, player: player)
                .frame(height: 96)
            HStack(spacing: 0) {
                TimeField(title: "Start", value: model.start, longForm: source.longForm,
                          enabled: model.canEdit, alignment: .leading) { set(.start, $0) }
                Spacer(minLength: 12)
                TimeField(title: "End", value: model.canEdit ? model.end : 0, longForm: source.longForm,
                          enabled: model.canEdit, alignment: .trailing) { set(.end, $0) }
            }
            .frame(height: 16)
            .padding(.top, 7)
            autoRow
                .frame(height: 20)
                .padding(.top, 13)
                .padding(.leading, 6)
            HStack {
                Spacer()
                Button(action: model.togglePlay) {
                    Label {
                        Text("Play Selected Range")
                    } icon: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .disabled(!model.canEdit || player.unavailable)
                .help(player.isPlaying ? "Pause" : "Play from start to end")
            }
            .padding(.top, 8)
            .padding(.trailing, 6)
            .padding(.bottom, 12)
            AudioToolKit.SpaceKey { model.togglePlay() }
        }
    }

    private var autoRow: some View {
        HStack(spacing: 10) {
            Toggle("Trim silent ends automatically", isOn: Binding(
                get: { model.autoTrim },
                set: { on in withAnimation(AudioToolKit.Look.spring(reduceMotion)) { model.setAutoTrim(on) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(!isAvailable)
            if let note {
                Text(note)
                    .font(ToolStyle.label)
                    .foregroundStyle(ToolStyle.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: note)
    }

    private var isAvailable: Bool {
        if case .bounds = model.sound { return true }
        return false
    }

    private var note: String? {
        switch model.sound {
        case .nothingToTrim: "No silence at the ends"
        case .silent: "This recording is silent"
        default: nil
        }
    }

    private func set(_ edge: TrimEdge, _ value: Double) {
        withAnimation(AudioToolKit.Look.spring(reduceMotion)) { model.set(edge, value) }
    }
}

/// The waveform in its orange trim frame: handles on both ends, the kept part tinted and in
/// colour, the rest grey.
private struct TrimLane: View {
    @ObservedObject var model: TrimModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: TrimEdge?
    @State private var hovering: TrimEdge?
    @State private var anchor: Double = 0
    @State private var wasSnapped = false
    @State private var resume = false

    /// Measured from the original: 16pt handles with a 2 x 22pt grip, 2pt rails.
    static let handle: CGFloat = 16
    static let rail: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let axis = max(1, size.width - Self.handle * 2)
            let x0 = x(model.start, axis)
            let x1 = x(model.canEdit ? model.end : model.duration, axis)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                    .fill(AudioToolKit.Look.lane)
                if let failure = source.failure {
                    AudioToolKit.LaneMessage(text: failure)
                } else {
                    Rectangle()
                        .fill(AudioToolKit.Look.tint)
                        .frame(width: max(0, x1 - x0), height: size.height - Self.rail * 2)
                        .offset(x: x0, y: Self.rail)
                    waveform(axis: axis, height: size.height, x0: x0, x1: x1)
                    seekArea(axis: axis, x0: x0, x1: x1, height: size.height)
                    TrimFrame(x0: x0, x1: x1, handle: Self.handle, rail: Self.rail)
                        .fill(ToolStyle.orange, style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    grip(.start, center: x0 - Self.handle / 2, height: size.height)
                    grip(.end, center: x1 + Self.handle / 2, height: size.height)
                    playhead(axis: axis, height: size.height)
                    handleArea(.start, center: x0 - Self.handle / 2, axis: axis, height: size.height)
                    handleArea(.end, center: x1 + Self.handle / 2, axis: axis, height: size.height)
                }
            }
        }
    }

    private func x(_ time: Double, _ axis: CGFloat) -> CGFloat {
        let d = model.duration
        guard d > 0 else { return time > 0 ? Self.handle + axis : Self.handle }
        return Self.handle + axis * CGFloat(min(1, max(0, time / d)))
    }

    @ViewBuilder
    private func waveform(axis: CGFloat, height: CGFloat, x0: CGFloat, x1: CGFloat) -> some View {
        let inner = max(1, axis - 4)
        let lane = height - Self.rail * 2
        Group {
            if source.levels == nil {
                AudioToolKit.LoadingLine(color: ToolStyle.orange.opacity(0.6))
            } else {
                let values = source.bars(AudioToolKit.Bars.count(for: inner))
                let scale = 1 / Double(max(source.maxPeak, 0.01))
                ZStack {
                    AudioToolKit.Bars(values: values, scale: scale)
                        .fill(AudioToolKit.Look.grey)
                    AudioToolKit.Bars(values: values, scale: scale)
                        .fill(ToolStyle.orange)
                        .mask(alignment: .topLeading) {
                            Rectangle()
                                .frame(width: max(0, x1 - x0), height: lane)
                                .offset(x: x0 - Self.handle - 2)
                        }
                }
                .animation(AudioToolKit.Look.spring(reduceMotion), value: scale)
            }
        }
        .frame(width: inner, height: lane)
        .offset(x: Self.handle + 2, y: Self.rail)
        .allowsHitTesting(false)
    }

    private func grip(_ edge: TrimEdge, center: CGFloat, height: CGFloat) -> some View {
        let active = dragging == edge || hovering == edge
        return ZStack {
            if dragging == edge {
                UnevenRoundedRectangle(topLeadingRadius: edge == .start ? AudioToolKit.Look.corner : 0,
                                       bottomLeadingRadius: edge == .start ? AudioToolKit.Look.corner : 0,
                                       bottomTrailingRadius: edge == .end ? AudioToolKit.Look.corner : 0,
                                       topTrailingRadius: edge == .end ? AudioToolKit.Look.corner : 0,
                                       style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: Self.handle, height: height)
                    .transition(.opacity)
            }
            Capsule()
                .fill(Color.white)
                .frame(width: 2, height: active ? 28 : 22)
        }
        .frame(width: Self.handle, height: height)
        .position(x: center, y: height / 2)
        .animation(AudioToolKit.Look.spring(reduceMotion), value: active)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func playhead(axis: CGFloat, height: CGFloat) -> some View {
        if model.canEdit, model.playheadVisible {
            AudioToolKit.Live(active: player.isPlaying) {
                AudioToolKit.Playhead()
                    .frame(height: height - Self.rail * 2)
                    .offset(x: x(player.time, axis) - 1, y: Self.rail)
            }
            .allowsHitTesting(false)
        }
    }

    /// Clicking inside the kept part moves the playhead there.
    private func seekArea(axis: CGFloat, x0: CGFloat, x1: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: max(0, x1 - x0), height: height)
            .contentShape(Rectangle())
            .offset(x: x0)
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                guard model.canEdit, axis > 0 else { return }
                let time = model.start + Double(value.location.x / axis) * model.duration
                let t = min(max(model.start, time), model.end - 0.01)
                if player.isPlaying { model.play(from: t) } else { player.seek(t) }
            })
    }

    private func handleArea(_ edge: TrimEdge, center: CGFloat, axis: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.handle + 10, height: height)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
            .onHover { inside in
                if inside { hovering = edge } else if hovering == edge { hovering = nil }
            }
            .gesture(drag(edge, axis: axis))
            .allowsHitTesting(model.canEdit)
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "Start" : "End")
            .accessibilityValue(source.clock(edge == .start ? model.start : model.end))
            .accessibilityAdjustableAction { direction in
                let step = max(0.1, model.duration / 100)
                let now = edge == .start ? model.start : model.end
                model.set(edge, now + (direction == .increment ? step : -step))
            }
            .position(x: center, y: height / 2)
    }

    private func drag(_ edge: TrimEdge, axis: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard model.canEdit else { return }
                if dragging != edge {
                    dragging = edge
                    anchor = edge == .start ? model.start : model.end
                    wasSnapped = false
                    resume = player.isPlaying
                    player.pause()
                }
                let perPoint = model.duration / Double(axis)
                let raw = anchor + Double(value.translation.width) * perPoint
                let (target, snapped) = model.snapped(edge, raw, tolerance: perPoint * 5)
                if snapped && !wasSnapped { AudioToolKit.tick() }
                wasSnapped = snapped
                model.set(edge, target)
            }
            .onEnded { _ in
                dragging = nil
                if resume { model.play(from: model.start) }
                resume = false
            }
    }
}

/// The orange frame: rounded handles at both ends joined by thin rails, open in the middle.
private struct TrimFrame: Shape {
    var x0: CGFloat
    var x1: CGFloat
    var handle: CGFloat
    var rail: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(x0, x1) }
        set {
            x0 = newValue.first
            x1 = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = max(0, x1 - x0)
        let corner = AudioToolKit.Look.corner
        path.addRoundedRect(in: CGRect(x: x0 - handle, y: rect.minY, width: width + handle * 2, height: rect.height),
                            cornerSize: CGSize(width: corner, height: corner), style: .continuous)
        if width > 0 {
            path.addRect(CGRect(x: x0, y: rect.minY + rail, width: width, height: rect.height - rail * 2))
        }
        return path
    }
}

/// "Start 0:00.00" in SF Mono. The time is typeable: click, type 1:23.45, press Return.
private struct TimeField: View {
    var title: String
    var value: Double
    var longForm: Bool
    var enabled: Bool
    var alignment: HorizontalAlignment
    var commit: (Double) -> Void
    @State private var text = ""
    @State private var hovering = false
    @State private var shakes = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .focused($focused)
                .frame(width: CGFloat(formatted.count) * 6 + 2)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.08 : (hovering && enabled ? 0.05 : 0))))
                .padding(.horizontal, -3)
                .onHover { hovering = $0 }
                .onSubmit(apply)
                .disabled(!enabled)
                .help("Type a time like 1:23.45")
                .modifier(Shake(phase: CGFloat(shakes)))
        }
        .font(AudioToolKit.Look.clock)
        .foregroundStyle(ToolStyle.secondary)
        .onAppear { text = formatted }
        .onChange(of: formatted) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, now in if !now { apply() } }
    }

    private var formatted: String { AudioToolKit.clock(value, hours: longForm) }

    private func apply() {
        guard text != formatted else { return }
        if let seconds = AudioToolKit.parseClock(text) {
            commit(seconds)
            text = formatted
        } else {
            text = formatted
            if !reduceMotion { withAnimation(.linear(duration: 0.28)) { shakes += 1 } }
        }
    }
}

/// A quick side to side shake for input that couldn't be read.
private struct Shake: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 3 * sin(phase * .pi * 4), y: 0))
    }
}

// MARK: - Processing

extension AudioToolKit {
    enum Trimmer {
        /// Writes `start...end` (nil end: to the end of the file) in the source's format.
        /// Lossy files that only lose their tail are cut without re-encoding (the cut lands
        /// on the nearest frame, a few hundredths of a second); everything else is re-encoded
        /// with the same codec, which is sample accurate.
        static func run(_ src: URL, to out: URL, start: Double, end: Double?, ctx: JobContext) throws {
            let info = try AudioToolKit.probe(src, ctx: ctx)
            let from = max(0, start)
            let stop = end.map { max(from + 0.001, $0) }
            let length = (stop ?? info.duration) - from
            let ext = out.pathExtension.lowercased()
            let duration = ["-t", String(format: "%.6f", length)]
            if from < 0.0005, !info.isLossless, canCopy(info, ext) {
                do {
                    try MediaEngine.ffmpeg(["-i", src.path] + copyArguments(info, ext) + (stop == nil ? [] : duration) + [out.path],
                                           duration: length, ctx: ctx)
                    return
                } catch JobError.cancelled {
                    throw JobError.cancelled
                } catch {
                    try? FileManager.default.removeItem(at: out)
                }
            }
            try AudioToolKit.render(src, info: info, filter: nil, to: out, ctx: ctx,
                                    inputOptions: from > 0 ? ["-ss", String(format: "%.6f", from)] : [],
                                    outputOptions: stop == nil ? [] : duration)
        }

        static func canCopy(_ info: Info, _ ext: String) -> Bool {
            switch ext {
            case "mp3": info.codec == "mp3"
            case "m4a", "m4b", "mp4", "aac": info.codec == "aac"
            case "ogg", "oga": info.codec == "vorbis"
            case "opus": info.codec == "opus"
            default: false
            }
        }

        /// Same streams, tags and cover, packets copied as they are.
        static func copyArguments(_ info: Info, _ ext: String) -> [String] {
            var a = ["-map", "0:a:0"]
            if info.hasCover && ["mp3", "m4a", "m4b", "flac"].contains(ext) {
                a += ["-map", "0:v?", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
            } else {
                a += ["-vn"]
            }
            a += ["-sn", "-dn", "-map_metadata", "0", "-c:a", "copy"]
            if ext == "mp3" { a += ["-id3v2_version", "3"] }
            if ["m4a", "m4b", "mp4"].contains(ext) { a += ["-movflags", "+faststart"] }
            return a
        }
    }
}
