import Combine
import SwiftUI

/// Bleep Audio: drag across the Bleep layer to mark sections, compare Original and With
/// Bleeps, and save "name Bleeped.ext": the sound inside each section is replaced by a
/// 1 kHz tone at the recording's own level, same format as the source.
struct BleepAudioTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: BleepModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: BleepModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            BleepContent(model: model, source: model.source, player: model.player)
        } footer: {
            // The original has no Reset here, just the action.
            ToolFooter(showsReset: false, primaryTitle: "Save Bleeped Copy",
                       primaryEnabled: model.canApply, onPrimary: apply)
        }
        .background(AudioToolKit.CloseHook { model.close() })
    }

    private func apply() {
        let ranges = model.bleeps.map { $0.start...$0.end }
        let level = model.toneLevel
        model.close()
        session.runEach { src, out, ctx in
            try AudioToolKit.Bleeper.run(src, to: out, ranges: ranges, amplitude: level, ctx: ctx)
        }
    }
}

// MARK: - Model

private struct Bleep: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double

    var length: Double { end - start }
}

@MainActor
private final class BleepModel: ObservableObject {
    enum Mode { case original, bleeped }

    let source: AudioToolKit.Source
    let player: AudioToolKit.Player
    @Published private(set) var bleeps: [Bleep] = [] { didSet { push() } }
    /// The section being drawn right now, before it's let go.
    @Published private(set) var draft: Bleep? { didSet { push() } }
    @Published var selection: UUID?
    @Published private(set) var mode = Mode.bleeped
    @Published private(set) var toneLevel: Float = 0.25
    private let shared = AudioToolKit.Locked(AudioToolKit.Bleeper.Preview())
    private var watch: AnyCancellable?
    private var resumeAfterScrub = false
    private var scrubbing = false

    init(url: URL) {
        source = AudioToolKit.Source(url)
        player = AudioToolKit.Player(url: url)
        let box = shared
        player.setProcessor { chunk in AudioToolKit.Bleeper.apply(box.value, to: chunk) }
        watch = source.$phase.sink { [weak self] phase in
            guard phase == .ready else { return }
            // Runs as the phase changes, when the levels are already in place.
            MainActor.assumeIsolated { self?.levelsReady() }
        }
        push()
    }

    var duration: Double { source.duration }
    var canEdit: Bool { source.info != nil && source.failure == nil && duration > 0 }
    var canApply: Bool { canEdit && !bleeps.isEmpty }
    var selected: Bleep? { bleeps.first { $0.id == selection } }
    /// The shortest bleep, a twentieth of a second.
    var minLength: Double { min(0.05, duration) }

    private func levelsReady() {
        guard let levels = source.levels else { return }
        toneLevel = AudioToolKit.Bleeper.level(for: levels)
        push()
    }

    // MARK: Editing

    /// The free stretch around `time`, between the bleeps on either side.
    func gap(around time: Double) -> ClosedRange<Double> {
        var lo = 0.0
        var hi = duration
        for b in bleeps {
            if b.end <= time { lo = max(lo, b.end) }
            if b.start >= time { hi = min(hi, b.start) }
        }
        return lo...max(lo, hi)
    }

    /// How far a bleep can travel without running into its neighbours.
    private func room(for id: UUID) -> ClosedRange<Double> {
        guard let me = bleeps.first(where: { $0.id == id }) else { return 0...duration }
        var lo = 0.0
        var hi = duration
        for b in bleeps where b.id != id {
            if b.end <= me.start + 1e-9 { lo = max(lo, b.end) }
            if b.start >= me.end - 1e-9 { hi = min(hi, b.start) }
        }
        return lo...max(lo, hi)
    }

    func sketch(from anchor: Double, to time: Double, within gap: ClosedRange<Double>) {
        let a = min(max(anchor, gap.lowerBound), gap.upperBound)
        let b = min(max(time, gap.lowerBound), gap.upperBound)
        draft = Bleep(id: draft?.id ?? UUID(), start: min(a, b), end: max(a, b))
    }

    /// Keeps the drawn section if it's long enough to hear.
    func commitSketch() {
        guard let d = draft else { return }
        draft = nil
        guard d.length >= minLength * 0.99 else { return }
        bleeps = (bleeps + [d]).sorted { $0.start < $1.start }
        selection = d.id
        AudioToolKit.tick()
    }

    func cancelSketch() { draft = nil }

    func move(_ id: UUID, from original: Bleep, by delta: Double) {
        guard let i = bleeps.firstIndex(where: { $0.id == id }) else { return }
        let room = room(for: id)
        let start = min(max(room.lowerBound, original.start + delta), room.upperBound - original.length)
        bleeps[i].start = start
        bleeps[i].end = start + original.length
    }

    func resize(_ id: UUID, edge: HorizontalEdge, to time: Double) {
        guard let i = bleeps.firstIndex(where: { $0.id == id }) else { return }
        let room = room(for: id)
        if edge == .leading {
            bleeps[i].start = min(max(room.lowerBound, time), bleeps[i].end - minLength)
        } else {
            bleeps[i].end = max(min(room.upperBound, time), bleeps[i].start + minLength)
        }
    }

    func delete(_ id: UUID) {
        bleeps.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func deleteSelected() {
        if let id = selection { delete(id) }
    }

    // MARK: Listening

    /// The active mode's button plays and pauses; the other one switches over and plays.
    func press(_ next: Mode) {
        guard canEdit, !player.unavailable else { return }
        guard mode != next else {
            togglePlay()
            return
        }
        mode = next
        push()
        if player.isPlaying { player.refresh() } else { togglePlay() }
    }

    func togglePlay() {
        guard canEdit, !player.unavailable else { return }
        if player.isPlaying {
            player.pause()
            return
        }
        let atEnd = player.parked >= duration - 0.02
        player.play(from: atEnd ? 0 : player.parked)
    }

    /// Dragging along a lane pauses, moves the playhead, and picks up again on release.
    func scrub(to time: Double) {
        guard canEdit else { return }
        if !scrubbing {
            scrubbing = true
            resumeAfterScrub = player.isPlaying
            player.pause()
        }
        player.seek(min(max(0, time), duration))
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        if resumeAfterScrub { player.play(from: player.parked) }
        resumeAfterScrub = false
    }

    func close() {
        player.close()
        source.cancel()
    }

    private func push() {
        var ranges = bleeps.map { $0.start...$0.end }
        if let d = draft, d.length > 0 { ranges.append(d.start...d.end) }
        shared.value = AudioToolKit.Bleeper.Preview(ranges: ranges, amplitude: toneLevel, on: mode == .bleeped)
    }
}

// MARK: - Views

private enum BleepLayout {
    static let labels: CGFloat = 54
    static let bleepLane: CGFloat = 28
    static let audioLane: CGFloat = 64
    static let gap: CGFloat = 7
    static let space = "bleepLanes"
}

private struct BleepContent: View {
    @ObservedObject var model: BleepModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 15)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Bleep")
                        .frame(height: BleepLayout.bleepLane)
                    Text("Audio")
                        .frame(height: BleepLayout.audioLane)
                        .padding(.top, BleepLayout.gap)
                }
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: BleepLayout.labels, alignment: .leading)
                BleepLanes(model: model, source: source, player: player)
                    .frame(height: BleepLayout.bleepLane + BleepLayout.gap + BleepLayout.audioLane)
            }
            .padding(.top, 5)
            HStack {
                Text(source.clock(0))
                Spacer()
                Text(model.canEdit ? source.clock(model.duration) : "")
            }
            .font(AudioToolKit.Look.clock)
            .foregroundStyle(ToolStyle.secondary)
            .padding(.leading, BleepLayout.labels + 6)
            .padding(.trailing, 2)
            .frame(height: 12)
            .padding(.top, 8)
            Text("Drag across the Bleep layer to add a section, then drag a clip or either edge to adjust it.")
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 32, alignment: .topLeading)
                .padding(.top, 18)
                .padding(.horizontal, 6)
            Divider()
                .padding(.top, 12)
                .padding(.horizontal, 6)
            previewRow
                .frame(height: 24)
                .padding(.top, 10)
                .padding(.horizontal, 6)
                .padding(.bottom, 47)
            keys
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bleeps")
                .font(.system(size: 12, weight: .semibold))
            Text("\(model.bleeps.count)")
                .foregroundStyle(ToolStyle.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: model.bleeps.count)
            Spacer(minLength: 8)
            if let b = model.selected {
                Text(source.clock(b.start) + " to " + source.clock(b.end))
                    .font(ToolStyle.mono)
                    .foregroundStyle(ToolStyle.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
                RemoveButton { withAnimation(AudioToolKit.Look.spring(reduceMotion)) { model.deleteSelected() } }
                    .transition(.opacity)
            }
        }
        .font(ToolStyle.label)
        .animation(.easeOut(duration: 0.15), value: model.selection)
    }

    private var previewRow: some View {
        HStack(spacing: 12) {
            Text("Preview")
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
            Spacer()
            modeButton("Original", .original)
            modeButton("With Bleeps", .bleeped)
        }
        .animation(AudioToolKit.Look.spring(reduceMotion), value: model.mode)
    }

    /// The selected preview carries the play or pause symbol.
    private func modeButton(_ title: String, _ mode: BleepModel.Mode) -> some View {
        Button {
            model.press(mode)
        } label: {
            HStack(spacing: 6) {
                if model.mode == mode {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                Text(title)
            }
        }
        .disabled(!model.canEdit || player.unavailable)
        .help(model.mode == mode ? (player.isPlaying ? "Pause" : "Play") : "Listen to the \(title.lowercased()) version")
    }

    /// Space plays; Delete removes the selected bleep.
    private var keys: some View {
        ZStack {
            AudioToolKit.SpaceKey { model.togglePlay() }
            if model.selection != nil {
                Button("") { withAnimation(AudioToolKit.Look.spring(reduceMotion)) { model.deleteSelected() } }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("") { withAnimation(AudioToolKit.Look.spring(reduceMotion)) { model.deleteSelected() } }
                    .keyboardShortcut(.deleteForward, modifiers: [])
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The ⊖ that removes the selected bleep.
private struct RemoveButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? AnyShapeStyle(ToolStyle.orange) : AnyShapeStyle(ToolStyle.secondary))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove this bleep")
        .accessibilityLabel("Remove bleep")
    }
}

/// The Bleep layer over the Audio layer, sharing one time axis and one playhead.
private struct BleepLanes: View {
    @ObservedObject var model: BleepModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sketchGap: ClosedRange<Double>?
    @State private var sketchAnchor: Double = 0
    @State private var hoverInLane = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                bleepLane(width: width)
                    .frame(width: width, height: BleepLayout.bleepLane)
                audioLane(width: width)
                    .frame(width: width, height: BleepLayout.audioLane)
                    .offset(y: BleepLayout.bleepLane + BleepLayout.gap)
                if model.canEdit {
                    AudioToolKit.Live(active: player.isPlaying) {
                        let x = position(player.time, width) - 0.5
                        ZStack(alignment: .topLeading) {
                            AudioToolKit.Playhead(color: ToolStyle.secondary, width: 1)
                                .frame(height: BleepLayout.bleepLane)
                                .offset(x: x)
                            AudioToolKit.Playhead(color: ToolStyle.secondary, width: 1)
                                .frame(height: BleepLayout.audioLane)
                                .offset(x: x, y: BleepLayout.bleepLane + BleepLayout.gap)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(BleepLayout.space))
        }
    }

    private func position(_ time: Double, _ width: CGFloat) -> CGFloat {
        let d = model.duration
        guard d > 0 else { return 0 }
        return width * CGFloat(min(1, max(0, time / d)))
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * model.duration
    }

    // MARK: Bleep layer

    private func bleepLane(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                .fill(AudioToolKit.Look.lane)
                .contentShape(Rectangle())
                .pointerStyle(model.canEdit ? .rectSelection : nil)
                .gesture(sketch(width: width))
            ForEach(model.bleeps) { bleep in
                BleepClip(model: model, bleep: bleep, width: width)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
            }
            if let draft = model.draft {
                ClipFace(width: position(draft.end, width) - position(draft.start, width), selected: true, hovering: false)
                    .frame(width: max(1, position(draft.end, width) - position(draft.start, width)),
                           height: BleepLayout.bleepLane)
                    .offset(x: position(draft.start, width))
                    .allowsHitTesting(false)
            }
        }
        .animation(AudioToolKit.Look.spring(reduceMotion), value: model.bleeps.map(\.id))
        .disabled(!model.canEdit)
    }

    /// Drag across empty space to draw a bleep; a plain click deselects and moves the playhead.
    private func sketch(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(BleepLayout.space))
            .onChanged { value in
                guard model.canEdit else { return }
                let at = time(at: value.startLocation.x, width)
                if sketchGap == nil {
                    sketchGap = model.gap(around: at)
                    sketchAnchor = at
                }
                guard abs(value.translation.width) >= 3, let gap = sketchGap else { return }
                model.sketch(from: sketchAnchor, to: time(at: value.location.x, width), within: gap)
            }
            .onEnded { value in
                defer { sketchGap = nil }
                guard model.canEdit else { return }
                if abs(value.translation.width) < 3 {
                    model.cancelSketch()
                    model.selection = nil
                    model.scrub(to: time(at: value.location.x, width))
                    model.endScrub()
                } else {
                    withAnimation(AudioToolKit.Look.spring(reduceMotion)) { model.commitSketch() }
                }
            }
    }

    // MARK: Audio layer

    @ViewBuilder private func audioLane(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                .fill(AudioToolKit.Look.lane)
            if let failure = source.failure {
                AudioToolKit.LaneMessage(text: failure)
            } else if source.levels == nil {
                AudioToolKit.LoadingLine(color: AudioToolKit.Look.soft)
                    .padding(.horizontal, 3)
            } else {
                let inner = max(1, width - 4)
                AudioToolKit.Bars(values: source.bars(AudioToolKit.Bars.count(for: inner)),
                                  scale: 1 / Double(max(source.maxPeak, 0.01)), fill: 0.8)
                    .fill(AudioToolKit.Look.soft)
                    .frame(width: inner)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(BleepLayout.space))
            .onChanged { value in model.scrub(to: time(at: value.location.x, width)) }
            .onEnded { _ in model.endScrub() })
    }
}

/// One bleep: drag the middle to move it, either edge to resize, right-click to remove.
private struct BleepClip: View {
    @ObservedObject var model: BleepModel
    var bleep: Bleep
    var width: CGFloat
    @State private var original: Bleep?
    @State private var hovering = false
    @State private var moving = false

    var body: some View {
        let x0 = x(bleep.start)
        let w = max(2, x(bleep.end) - x0)
        let edge = min(8, max(3, w / 3))
        ZStack(alignment: .topLeading) {
            ClipFace(width: w, selected: model.selection == bleep.id, hovering: hovering)
                .frame(width: w, height: BleepLayout.bleepLane)
                .contentShape(Rectangle())
                .pointerStyle(moving ? .grabActive : .grabIdle)
                .onHover { hovering = $0 }
                .gesture(move)
            handle(.leading, width: edge + 3)
                .offset(x: -3)
            handle(.trailing, width: edge + 3)
                .offset(x: w - edge)
        }
        .frame(width: w, height: BleepLayout.bleepLane, alignment: .topLeading)
        .offset(x: x0)
        .contextMenu {
            Button("Remove Bleep", role: .destructive) { model.delete(bleep.id) }
        }
        .accessibilityElement()
        .accessibilityLabel("Bleep")
        .accessibilityValue(AudioToolKit.clock(bleep.start) + " to " + AudioToolKit.clock(bleep.end))
        .accessibilityAction(named: "Remove") { model.delete(bleep.id) }
    }

    private func x(_ time: Double) -> CGFloat {
        let d = model.duration
        guard d > 0 else { return 0 }
        return width * CGFloat(min(1, max(0, time / d)))
    }

    private var secondsPerPoint: Double { width > 0 ? model.duration / Double(width) : 0 }

    private var move: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(BleepLayout.space))
            .onChanged { value in
                if original == nil {
                    original = bleep
                    model.selection = bleep.id
                    moving = true
                }
                guard let original else { return }
                model.move(bleep.id, from: original, by: Double(value.translation.width) * secondsPerPoint)
            }
            .onEnded { _ in
                original = nil
                moving = false
            }
    }

    private func handle(_ edge: HorizontalEdge, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: BleepLayout.bleepLane)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(BleepLayout.space))
                .onChanged { value in
                    if original == nil {
                        original = bleep
                        model.selection = bleep.id
                    }
                    model.resize(bleep.id, edge: edge, to: Double(value.location.x) * secondsPerPoint)
                }
                .onEnded { _ in original = nil })
    }
}

/// The salmon clip with its label and grips, as the original draws it.
private struct ClipFace: View {
    var width: CGFloat
    var selected: Bool
    var hovering: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                .fill(ToolStyle.orange.opacity(selected ? 0.8 : (hovering ? 0.64 : 0.55)))
            if selected {
                RoundedRectangle(cornerRadius: AudioToolKit.Look.corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            }
            if width >= 58 {
                Text("Bleep")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if width >= 14 {
                HStack {
                    Capsule().fill(Color.white).frame(width: 2, height: 13)
                    Spacer(minLength: 0)
                    Capsule().fill(Color.white).frame(width: 2, height: 13)
                }
                .padding(.horizontal, 4)
            }
        }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Processing

extension AudioToolKit {
    enum Bleeper {
        /// Edges cross-fade over 4 ms so the cut never clicks.
        static let fade = 0.004
        static let frequency = 1000.0

        /// What the preview applies on the audio thread.
        struct Preview {
            var ranges: [ClosedRange<Double>] = []
            var amplitude: Float = 0.25
            var on = true
        }

        /// The tone sits at the level of the speech around it: a sine with the same RMS as the
        /// parts that aren't silent, kept between −30 dBFS and −6 dBFS.
        static func level(for levels: Levels) -> Float {
            min(0.5, max(0.03, levels.activeRMS() * Float(2.0.squareRoot())))
        }

        /// The same gate and tone as the saved file, sample by sample.
        static func apply(_ p: Preview, to c: Chunk) {
            guard p.on, !p.ranges.isEmpty, c.frames > 0 else { return }
            let t0 = c.start
            let t1 = t0 + Double(c.frames) / c.sampleRate
            let hits = p.ranges.filter { $0.upperBound + fade > t0 && $0.lowerBound - fade < t1 }
            guard !hits.isEmpty else { return }
            let w = 2 * Double.pi * frequency
            for i in 0..<c.frames {
                let t = t0 + Double(i) / c.sampleRate
                var g = 0.0
                for h in hits {
                    g += min(1, max(0, min(t - h.lowerBound, h.upperBound - t) / fade + 0.5))
                }
                guard g > 0 else { continue }
                let k = Float(min(1, g))
                let tone = Float(sin(w * t)) * p.amplitude * k
                c.left[i] = c.left[i] * (1 - k) + tone
                c.right[i] = c.right[i] * (1 - k) + tone
            }
        }

        /// `aeval` only runs near the bleeps (timeline `enable`), so the rest of the file passes
        /// through untouched and long files stay quick.
        static func filter(ranges: [ClosedRange<Double>], amplitude: Float, channels: Int) -> String {
            func n(_ v: Double) -> String { String(format: "%.6f", v) }
            let gate = ranges.map { r in
                "clip(min(t-\(n(r.lowerBound)),\(n(r.upperBound))-t)/\(n(fade))+0.5,0,1)"
            }.joined(separator: "+")
            let tone = "\(String(format: "%.6f", Double(amplitude)))*sin(\(n(2 * Double.pi * frequency))*t)"
            let exprs = (0..<max(1, channels)).map { c in
                "st(0,min(1,\(gate)));val(\(c))*(1-ld(0))+ld(0)*\(tone)"
            }.joined(separator: "|")
            let enable = ranges.map { r in
                "between(t,\(n(r.lowerBound - 0.25)),\(n(r.upperBound + 0.25)))"
            }.joined(separator: "+")
            return "asetpts=PTS-STARTPTS,asetnsamples=n=1024:p=0,aeval=exprs='\(exprs)':c=same:enable='\(enable)'"
        }

        static func run(_ src: URL, to out: URL, ranges: [ClosedRange<Double>], amplitude: Float, ctx: JobContext) throws {
            guard !ranges.isEmpty else { throw JobError.failed("Add a bleep first.") }
            let info = try AudioToolKit.probe(src, ctx: ctx)
            let chain = filter(ranges: ranges, amplitude: amplitude, channels: info.channels)
                + "," + AudioToolKit.finishingFilter(for: info, ext: out.pathExtension, dither: false)
            try AudioToolKit.render(src, info: info, filter: chain, to: out, ctx: ctx)
        }
    }
}
