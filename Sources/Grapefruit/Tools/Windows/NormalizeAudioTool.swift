import SwiftUI

/// Normalize Volume: measures each recording (EBU R128) and brings it to a target loudness
/// with ffmpeg's two-pass loudnorm. The waveform shows real levels, so flipping between
/// Original and Normalized compares input and result, by eye and by ear.
struct NormalizeAudioTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: NormalizeModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: NormalizeModel(urls: session.urls))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            NormalizeContent(model: model, source: model.source, player: model.player)
        } footer: {
            // The original has no Reset here, just the action.
            ToolFooter(showsReset: false, primaryTitle: "Normalize Audio",
                       primaryEnabled: model.canApply, onPrimary: apply)
        }
        .background(AudioToolKit.CloseHook { model.close() })
    }

    private func apply() {
        let targets = model.targets
        let measured = model.measuredByURL
        model.close()
        session.runEach { src, out, ctx in
            try AudioToolKit.Normalizer.run(src, to: out, targets: targets, measured: measured[src], ctx: ctx)
        }
    }
}

// MARK: - Model

@MainActor
private final class NormalizeModel: ObservableObject {
    enum Side: Hashable { case original, normalized }

    enum Reading: Equatable {
        case waiting
        case measuring(Int)
        case done(AudioToolKit.Loudness)
        case failed

        var loudness: AudioToolKit.Loudness? {
            if case .done(let l) = self { return l }
            return nil
        }
        var isSilent: Bool { loudness?.isSilent ?? false }
        var isFailed: Bool { self == .failed }
    }

    let urls: [URL]
    @Published private(set) var index = 0
    @Published var targets = AudioToolKit.Normalizer.Targets() { didSet { pushPreview() } }
    @Published var side = Side.normalized { didSet { pushPreview() } }
    @Published private(set) var readings: [Reading]
    @Published private(set) var source: AudioToolKit.Source
    @Published private(set) var player: AudioToolKit.Player
    private var sources: [Int: AudioToolKit.Source] = [:]
    private let preview = AudioToolKit.Locked(AudioToolKit.Normalizer.Preview())
    private let ctx = AudioToolKit.windowContext()

    init(urls: [URL]) {
        self.urls = urls
        readings = Array(repeating: .waiting, count: urls.count)
        let first = AudioToolKit.Source(urls[0])
        source = first
        sources[0] = first
        player = AudioToolKit.Player(url: urls[0])
        attachProcessor()
        measureAll()
    }

    var reading: Reading { readings[index] }

    /// The comparison only means something once the file is measured and has sound.
    var canCompare: Bool { reading.loudness.map { !$0.isSilent } ?? false }

    var canApply: Bool {
        if urls.count == 1 {
            return source.failure == nil && !reading.isFailed && !reading.isSilent
        }
        return readings.contains { !$0.isFailed && !$0.isSilent }
    }

    /// Linear gain the waveform and the preview apply on the Normalized side.
    var gain: Double {
        guard side == .normalized, let l = reading.loudness, !l.isSilent else { return 1 }
        return pow(10, (targets.target - l.integrated) / 20)
    }

    /// Where the true peak limit sits, linear. Only on the Normalized side.
    var ceiling: Double {
        guard side == .normalized, canCompare else { return 1 }
        return pow(10, targets.peak / 20)
    }

    var measuredByURL: [URL: AudioToolKit.Loudness] {
        var map: [URL: AudioToolKit.Loudness] = [:]
        for (i, url) in urls.enumerated() {
            if let l = readings[i].loudness { map[url] = l }
        }
        return map
    }

    func step(_ delta: Int) {
        let next = min(max(0, index + delta), urls.count - 1)
        guard next != index else { return }
        player.close()
        index = next
        if let cached = sources[next] {
            source = cached
        } else {
            let fresh = AudioToolKit.Source(urls[next])
            sources[next] = fresh
            source = fresh
        }
        player = AudioToolKit.Player(url: urls[next])
        attachProcessor()
        pushPreview()
    }

    func togglePlay() {
        guard source.failure == nil else { return }
        if player.isPlaying {
            player.pause()
        } else {
            let atEnd = source.duration > 0 && player.parked >= source.duration - 0.02
            player.play(from: atEnd ? 0 : player.parked)
        }
    }

    func close() {
        ctx.cancel()
        player.close()
        sources.values.forEach { $0.cancel() }
    }

    private func attachProcessor() {
        let box = preview
        let ramp = AudioToolKit.Normalizer.Ramp()
        player.setProcessor { chunk in
            AudioToolKit.Normalizer.apply(box.value, to: chunk, ramp: ramp)
        }
    }

    /// New settings reach the audio a chunk or two later, with a short ramp, so dragging a
    /// slider while listening never clicks.
    private func pushPreview() {
        preview.value = AudioToolKit.Normalizer.Preview(gain: Float(gain), ceiling: Float(ceiling),
                                                        limits: side == .normalized && canCompare)
    }

    /// Measures every file in turn, in the background.
    private func measureAll() {
        let urls = urls
        let ctx = ctx
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (i, url) in urls.enumerated() {
                if ctx.isCancelled { return }
                let post: (Reading) -> Void = { reading in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(reading, at: i) } }
                }
                post(.measuring(0))
                do {
                    let duration = (try? AudioToolKit.probe(url, ctx: ctx))?.duration ?? 0
                    var shown = 0
                    let loudness = try AudioToolKit.Normalizer.measure(url, duration: duration, ctx: ctx) { fraction in
                        let percent = Int(fraction * 100)
                        guard percent != shown else { return }
                        shown = percent
                        post(.measuring(percent))
                    }
                    post(.done(loudness))
                } catch JobError.cancelled {
                    return
                } catch {
                    post(.failed)
                }
            }
        }
    }

    private func record(_ reading: Reading, at i: Int) {
        readings[i] = reading
        if i == index { pushPreview() }
    }
}

// MARK: - Views

private struct NormalizeContent: View {
    @ObservedObject var model: NormalizeModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 15)
                .padding(.bottom, 6)
            NormalizeWave(model: model, source: source, player: player)
                .frame(height: 240)
            playRow
                .frame(height: 28)
                .padding(.top, 6)
                .padding(.bottom, 16)
            VStack(spacing: 8) {
                TargetSlider(title: "Target loudness", value: $model.targets.target, range: -24 ... -5, step: 1,
                             text: AudioToolKit.signed(model.targets.target) + " LUFS")
                TargetSlider(title: "Loudness range", value: $model.targets.range, range: 1 ... 20, step: 1,
                             text: "\(Int(model.targets.range)) LU")
                TargetSlider(title: "True peak limit", value: $model.targets.peak, range: -9 ... 0, step: 0.5,
                             text: AudioToolKit.signed(model.targets.peak, decimals: 1) + " dBTP")
            }
            .padding(.horizontal, 6)
            .disabled(urls1Failed)
            Text(caption)
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 32, alignment: .topLeading)
                .padding(.top, 14)
            AudioToolKit.SpaceKey { model.togglePlay() }
        }
    }

    @ViewBuilder private var header: some View {
        if model.urls.count == 1 {
            AudioToolKit.NameRow(name: source.name, value: source.info == nil ? nil : source.clock(source.duration))
        } else {
            HStack(spacing: 2) {
                StepButton(symbol: "chevron.left", label: "Previous file", enabled: model.index > 0) { model.step(-1) }
                StepButton(symbol: "chevron.right", label: "Next file", enabled: model.index < model.urls.count - 1) { model.step(1) }
                Text(source.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.name)
                    .padding(.leading, 4)
                Spacer(minLength: 10)
                Text("\(model.index + 1) of \(model.urls.count)" + (source.info == nil ? "" : "  ·  " + source.clock(source.duration)))
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(ToolStyle.label)
            .foregroundStyle(ToolStyle.secondary)
        }
    }

    private var playRow: some View {
        HStack(spacing: 10) {
            AudioToolKit.PlainPlayButton(playing: player.isPlaying, enabled: source.failure == nil && !player.unavailable) {
                model.togglePlay()
            }
            Spacer(minLength: 0)
            Picker("Compare", selection: $model.side) {
                Text("Original").tag(NormalizeModel.Side.original)
                Text("Normalized").tag(NormalizeModel.Side.normalized)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(!model.canCompare)
            .help("Hear and see the file before and after")
            Spacer(minLength: 0)
            AudioToolKit.Live(active: player.isPlaying) {
                Text(source.clock(player.time) + " / " + source.clock(source.duration))
                    .font(ToolStyle.mono)
                    .foregroundStyle(ToolStyle.secondary)
                    .fixedSize()
            }
        }
    }

    private var urls1Failed: Bool { model.urls.count == 1 && source.failure != nil }

    private var caption: String {
        if model.urls.count == 1, model.reading.isSilent {
            return "This recording is silent, so there's nothing to normalize."
        }
        let t = Int(model.targets.target.rounded())
        let level = AudioToolKit.signed(Double(t)) + " LUFS"
        let first: String
        switch t {
        case ...(-20): first = "\(level) is quiet, close to TV broadcast levels."
        case -19 ... -17: first = "\(level) keeps extra headroom for dynamic music."
        case -16: first = "\(level) is a balanced default for spoken audio and music."
        case -15 ... -13: first = "\(level) is close to what streaming apps play at."
        default: first = "\(level) is very loud and can sound squashed."
        }
        return first + " The true peak limit helps prevent clipping after encoding."
    }
}

/// The big level-true waveform with the playhead, the measured loudness, and drag to scrub.
private struct NormalizeWave: View {
    @ObservedObject var model: NormalizeModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resumeAfterScrub = false
    @State private var scrubbing = false

    private let inset: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let inner = max(1, geo.size.width - inset * 2)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AudioToolKit.Look.lane)
                lane(width: inner)
                    .padding(.horizontal, inset)
                if source.failure == nil {
                    AudioToolKit.Live(active: player.isPlaying) {
                        AudioToolKit.Playhead()
                            .frame(height: geo.size.height)
                            .offset(x: inset + inner * fraction(player.time) - 1)
                    }
                }
                readout
                    .padding(.top, 9)
                    .padding(.leading, 11)
            }
            .contentShape(Rectangle())
            .gesture(scrub(width: inner))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform")
        .accessibilityValue(accessibilityText)
    }

    @ViewBuilder private func lane(width: CGFloat) -> some View {
        if let failure = source.failure {
            AudioToolKit.LaneMessage(text: failure)
        } else if source.levels == nil {
            AudioToolKit.LoadingLine(color: ToolStyle.orange.opacity(0.7))
        } else {
            let n = AudioToolKit.Bars.count(for: width)
            AudioToolKit.Bars(values: source.bars(n), scale: model.gain, ceiling: model.ceiling, fill: 0.9)
                .fill(ToolStyle.orange)
                .animation(AudioToolKit.Look.spring(reduceMotion), value: model.gain)
                .animation(AudioToolKit.Look.spring(reduceMotion), value: model.ceiling)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var readout: some View {
        Group {
            switch model.reading {
            case .waiting:
                Text(model.urls.count > 1 ? "Waiting to measure" : "")
            case .measuring(let percent):
                Text(percent > 0 ? "Measuring \(percent)%" : "Measuring")
            case .failed:
                Text(source.failure == nil ? "Couldn't measure loudness" : "")
            case .done(let l):
                Text(l.isSilent ? "Silent" : "Input " + AudioToolKit.signed(l.integrated, decimals: 1) + " LUFS")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(ToolStyle.secondary)
        .contentTransition(.numericText())
        .allowsHitTesting(false)
    }

    private var accessibilityText: String {
        switch model.reading {
        case .done(let l) where !l.isSilent:
            "Input loudness " + AudioToolKit.signed(l.integrated, decimals: 1) + " LUFS"
        case .done: "Silent"
        case .measuring: "Measuring loudness"
        default: source.failure ?? ""
        }
    }

    private func fraction(_ time: Double) -> CGFloat {
        let d = source.duration
        guard d > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / d)))
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard source.failure == nil, source.duration > 0 else { return }
                if !scrubbing {
                    scrubbing = true
                    resumeAfterScrub = player.isPlaying
                    player.pause()
                }
                let f = min(1, max(0, (value.location.x - inset) / width))
                player.seek(Double(f) * source.duration)
            }
            .onEnded { _ in
                guard scrubbing else { return }
                scrubbing = false
                if resumeAfterScrub { player.play(from: player.parked) }
            }
    }
}

/// "Target loudness ........ −16 LUFS" over a stepped slider with tick marks.
private struct TargetSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var text: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: text)
            }
            .font(ToolStyle.label)
            Slider(value: $value, in: range, step: step) {
                Text(title)
            } tick: { SliderTick($0) }
            .labelsHidden()
            .accessibilityValue(text)
        }
    }
}

/// A small chevron for stepping through a selection.
private struct StepButton: View {
    var symbol: String
    var label: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Processing

extension AudioToolKit {
    /// EBU R128 integrated loudness, true peak and loudness range.
    struct Loudness: Equatable {
        var integrated: Double
        var truePeak: Double
        var range: Double
        var threshold: Double

        /// ebur128 bottoms out at −70 LUFS for silence.
        var isSilent: Bool { !integrated.isFinite || integrated <= -69.5 }
    }

    enum Normalizer {
        struct Targets: Equatable {
            var target = -16.0
            var range = 11.0
            var peak = -1.5
        }

        /// What the preview applies on the audio thread.
        struct Preview {
            var gain: Float = 1
            var ceiling: Float = 1
            var limits = false
        }

        /// The gain the last chunk ended on. Only touched on the player's queue.
        final class Ramp: @unchecked Sendable {
            var gain: Float = 1
        }

        /// Gain, ramped across the chunk from where the last one ended, then a soft knee under
        /// the ceiling so the preview never clips (loudnorm's limiter does that job in the file).
        static func apply(_ p: Preview, to chunk: Chunk, ramp: Ramp) {
            let from = ramp.gain
            let to = p.gain
            ramp.gain = to
            guard from != 1 || to != 1 || p.limits else { return }
            let n = chunk.frames
            guard n > 0 else { return }
            let knee = p.ceiling * 0.8
            let room = max(0.0001, p.ceiling - knee)
            let step = (to - from) / Float(n)
            for channel in [chunk.left, chunk.right] {
                var g = from
                for i in 0..<n {
                    var y = channel[i] * g
                    g += step
                    if p.limits {
                        let a = abs(y)
                        if a > knee {
                            let over = knee + room * Float(tanh(Double((a - knee) / room)))
                            y = y < 0 ? -over : over
                        }
                    }
                    channel[i] = y
                }
            }
        }

        /// Measures with ffmpeg's ebur128 filter (several times faster than a loudnorm first
        /// pass and within a tenth of a LU of it). `progress` gets 0...1.
        static func measure(_ url: URL, duration: Double, ctx: JobContext?,
                            progress: ((Double) -> Void)? = nil) throws -> Loudness {
            let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
            let args = ["-hide_banner", "-nostdin", "-nostats", "-v", "info", "-progress", "pipe:1",
                        "-i", url.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
                        "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"]
            let result = try Shell.run(ffmpeg, args, ctx: ctx, collectOutput: false) { line in
                guard duration > 0, line.hasPrefix("out_time_us="),
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress?(min(1, max(0, us / 1_000_000 / duration)))
            }
            guard let loudness = parse(result.stderr) else {
                throw JobError.failed("Couldn't measure this file's loudness.")
            }
            return loudness
        }

        /// Reads the summary ebur128 prints when it finishes.
        static func parse(_ log: String) -> Loudness? {
            guard let summary = log.range(of: "Summary:", options: .backwards) else { return nil }
            var integrated: Double?
            var threshold: Double?
            var range: Double?
            var peak: Double?
            for raw in log[summary.upperBound...].split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                func value(_ prefix: String) -> Double? {
                    guard line.hasPrefix(prefix) else { return nil }
                    let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return Double(rest.split(separator: " ").first ?? "")
                }
                if integrated == nil, let v = value("I:") { integrated = v }
                else if integrated != nil, threshold == nil, let v = value("Threshold:") { threshold = v }
                else if range == nil, let v = value("LRA:") { range = v }
                else if peak == nil, let v = value("Peak:") { peak = v }
            }
            guard let integrated else { return nil }
            return Loudness(integrated: integrated, truePeak: peak ?? 0, range: range ?? 0,
                            threshold: threshold ?? integrated - 10)
        }

        /// Second loudnorm pass with the measured values (linear when the result fits under the
        /// peak limit and range), back at the source's sample rate, in the source's format.
        static func run(_ src: URL, to out: URL, targets: Targets, measured: Loudness?, ctx: JobContext) throws {
            let info = try AudioToolKit.probe(src, ctx: ctx)
            var start: Double
            let loudness: Loudness
            if let measured {
                loudness = measured
                start = 0
            } else {
                loudness = try measure(src, duration: info.duration, ctx: ctx) { ctx.progress($0 * 0.4) }
                start = 0.4
            }
            guard !loudness.isSilent else { throw JobError.failed("This recording is silent.") }
            var offset = 0.0
            // When one straight gain won't fit, loudnorm rides the gain and limits instead, and
            // lands up to a LU or so loud. A pass to nowhere says by how much; the real pass
            // starts that much lower. Clips under 3 s always get loudnorm's straight gain.
            if !isLinear(targets, loudness), info.duration >= 3 {
                let mid = start + (1 - start) * 0.5
                offset = try drift(src, filter: filter(targets, loudness), duration: info.duration,
                                   ctx: ctx, range: start...mid)
                start = mid
            }
            let chain = filter(targets, loudness, offset: offset) + ","
                + AudioToolKit.finishingFilter(for: info, ext: out.pathExtension)
            try AudioToolKit.render(src, info: info, filter: chain, to: out, ctx: ctx, range: start...1)
        }

        /// The first pass's numbers as loudnorm takes them. It reads 0 LUFS, 0 LRA and a −70
        /// threshold as "not measured" and then never goes linear, and a 1 s clip really does
        /// measure 0 LRA, so those get nudged by a hundredth.
        private static func inputs(_ m: Loudness) -> (integrated: Double, peak: Double, range: Double, threshold: Double) {
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
                let x = v.isFinite ? min(hi, max(lo, v)) : (v > 0 ? hi : lo)
                return (x * 100).rounded() / 100
            }
            let threshold = clamp(m.threshold, -99, 0)
            return (clamp(m.integrated, -99, -0.01), clamp(m.truePeak, -99, 98.99),
                    clamp(m.range, 0.01, 99), threshold == -70 ? -70.01 : threshold)
        }

        private static func limits(_ t: Targets) -> (target: Double, peak: Double, range: Double) {
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
                let x = v.isFinite ? min(hi, max(lo, v)) : lo
                return (x * 100).rounded() / 100
            }
            return (clamp(t.target, -70, -5), clamp(t.peak, -9, 0), clamp(t.range, 1, 50))
        }

        /// loudnorm's own test for a straight gain: the result fits under the peak limit and
        /// the range is already inside the target.
        static func isLinear(_ t: Targets, _ m: Loudness) -> Bool {
            let l = limits(t)
            let i = inputs(m)
            return i.peak + (l.target - i.integrated) <= l.peak && i.range <= l.range
        }

        /// Runs the loudnorm pass without writing anything and reads how far from the target it
        /// landed. 0 when it went linear after all or landed close enough.
        static func drift(_ src: URL, filter: String, duration: Double, ctx: JobContext,
                          range: ClosedRange<Double>) throws -> Double {
            let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
            let args = ["-hide_banner", "-nostdin", "-nostats", "-v", "info", "-progress", "pipe:1",
                        "-i", src.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
                        "-af", filter + ":print_format=json", "-f", "null", "-"]
            let span = range.upperBound - range.lowerBound
            let result = try Shell.run(ffmpeg, args, ctx: ctx, collectOutput: false) { line in
                guard duration > 0, line.hasPrefix("out_time_us="),
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                ctx.progress(range.lowerBound + span * min(1, max(0, us / 1_000_000 / duration)))
            }
            func field(_ name: String) -> String? {
                let log = result.stderr
                guard let key = log.range(of: "\"\(name)\" : \"", options: .backwards),
                      let end = log[key.upperBound...].firstIndex(of: "\"") else { return nil }
                return String(log[key.upperBound..<end])
            }
            guard field("normalization_type") == "dynamic",
                  let offset = field("target_offset").flatMap(Double.init), offset.isFinite,
                  abs(offset) >= 0.1 else { return 0 }
            return min(6, max(-6, offset))
        }

        /// loudnorm with the first pass's numbers, kept inside the ranges it accepts.
        static func filter(_ t: Targets, _ m: Loudness, offset: Double = 0) -> String {
            let l = limits(t)
            let i = inputs(m)
            func text(_ v: Double) -> String { String(format: "%.2f", v) }
            return "loudnorm=I=\(text(l.target)):TP=\(text(l.peak)):LRA=\(text(l.range))"
                + ":measured_I=\(text(i.integrated)):measured_TP=\(text(i.peak))"
                + ":measured_LRA=\(text(i.range)):measured_thresh=\(text(i.threshold))"
                + ":offset=\(text(offset)):linear=true"
        }
    }
}
