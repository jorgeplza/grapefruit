import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Audio Visualizer: an orange waveform (or a still picture) set to the recording, saved as
/// "name Visualizer.mp4". The preview is drawn by the same geometry as the video's frames,
/// and lights up bar by bar as it plays, exactly as the video will.
struct AudioVisualizerTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: VizModel

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: VizModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VizContent(model: model, source: model.source, player: model.player)
        } footer: {
            // The original has no Reset here, just the action.
            ToolFooter(showsReset: false, primaryTitle: "Create Visualization",
                       primaryEnabled: model.canApply, onPrimary: apply)
        }
        .background(AudioToolKit.CloseHook { model.close() })
    }

    private func apply() {
        let plan = model.plan
        model.close()
        session.runEach(ext: { _ in "mp4" }) { src, out, ctx in
            try AudioToolKit.Visualizer.run(src, to: out, plan: plan, ctx: ctx)
        }
    }
}

// MARK: - Model

@MainActor
private final class VizModel: ObservableObject {
    typealias Viz = AudioToolKit.Visualizer
    enum Backdrop: Hashable { case black, picture, choose }

    let source: AudioToolKit.Source
    let player: AudioToolKit.Player
    @Published var shape = Viz.Shape.landscape
    @Published private(set) var style = Viz.Style.waveform
    @Published private(set) var picture: Viz.Picture?
    /// Whether the waveform sits on the picture instead of black.
    @Published private(set) var onPicture = false
    @Published private(set) var loadingPicture = false
    private var scrubbing = false
    private var resumeAfterScrub = false

    init(url: URL) {
        source = AudioToolKit.Source(url)
        player = AudioToolKit.Player(url: url)
    }

    var usesPicture: Bool { picture != nil && (style == .still || onPicture) }
    var backdrop: Backdrop { usesPicture ? .picture : .black }
    var canApply: Bool { source.info != nil && source.failure == nil && (style == .waveform || picture != nil) }

    var plan: Viz.Plan {
        var values: [Float]?
        if let levels = source.levels, levels.complete {
            values = Viz.values(levels, count: Viz.count(for: shape))
        }
        let exact = source.levels?.complete == true ? source.duration : nil
        return Viz.Plan(source: source.url, style: style, shape: shape,
                        picture: usesPicture ? picture?.url : nil, values: values, duration: exact)
    }

    func pick(style next: Viz.Style) {
        guard next != style else { return }
        if next == .still, picture == nil {
            choosePicture { [weak self] in self?.style = .still }
        } else {
            style = next
        }
    }

    func pick(backdrop next: Backdrop) {
        switch next {
        case .black: onPicture = false
        case .picture: onPicture = picture != nil
        case .choose: choosePicture { [weak self] in self?.onPicture = true }
        }
    }

    /// Opens a picture as a sheet on the tool window, so it stays above the floating panel.
    private func choosePicture(then done: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for the video"
        panel.prompt = "Choose"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url, then: done)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }

    private func load(_ url: URL, then done: @escaping () -> Void) {
        loadingPicture = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Viz.loadPicture(url, maxPixels: 1600)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loadingPicture = false
                    guard let image else {
                        NSSound.beep()
                        return
                    }
                    self.picture = Viz.Picture(url: url, preview: image)
                    done()
                }
            }
        }
    }

    // MARK: Listening

    /// Bars lit so far, or nil for the resting poster where every bar is bright.
    func lit(at time: Double, count: Int) -> Int? {
        guard player.isPlaying || player.parked > 0.0005 else { return nil }
        return Viz.lit(time: time, duration: source.duration, count: count)
    }

    func togglePlay() {
        guard source.failure == nil, source.info != nil, !player.unavailable else { return }
        if player.isPlaying {
            player.pause()
            return
        }
        let d = source.duration
        let atEnd = d > 0 && player.parked >= d - 0.02
        player.play(from: atEnd ? 0 : player.parked, rewindTo: 0)
    }

    func scrub(to time: Double) {
        guard source.failure == nil else { return }
        if !scrubbing {
            scrubbing = true
            resumeAfterScrub = player.isPlaying
            player.pause()
        }
        player.seek(time)
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        if resumeAfterScrub { player.play(from: player.parked, rewindTo: 0) }
        resumeAfterScrub = false
    }

    func close() {
        player.close()
        source.cancel()
    }
}

// MARK: - Views

private struct VizContent: View {
    typealias Viz = AudioToolKit.Visualizer
    @ObservedObject var model: VizModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VizPreview(model: model, source: source, player: player)
                .frame(height: 405)
            VStack(spacing: 8) {
                row("Style") {
                    Picker("Style", selection: Binding(get: { model.style },
                                                       set: { new in withAnimation(.easeOut(duration: 0.2)) { model.pick(style: new) } })) {
                        Text("Waveform").tag(Viz.Style.waveform)
                        Text("Still Image").tag(Viz.Style.still)
                    }
                }
                row("Shape") {
                    Picker("Shape", selection: $model.shape.animation(AudioToolKit.Look.spring(reduceMotion))) {
                        ForEach(Viz.Shape.allCases, id: \.self) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                }
                row(model.style == .still ? "Image" : "Background") {
                    Picker("Background", selection: Binding(get: { model.backdrop },
                                                            set: { new in withAnimation(.easeOut(duration: 0.2)) { model.pick(backdrop: new) } })) {
                        if model.style == .waveform {
                            Text("Black").tag(VizModel.Backdrop.black)
                        }
                        if let picture = model.picture {
                            Text(picture.shortName).tag(VizModel.Backdrop.picture)
                        }
                        Divider()
                        Text("Choose Image…").tag(VizModel.Backdrop.choose)
                    }
                    .disabled(model.loadingPicture)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
            AudioToolKit.SpaceKey { model.togglePlay() }
        }
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
                .contentTransition(.opacity)
            Spacer()
            control()
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
        }
        .frame(height: 24)
    }
}

/// The video's frame in its shape: click to play or pause, drag across to scrub.
private struct VizPreview: View {
    typealias Viz = AudioToolKit.Visualizer
    @ObservedObject var model: VizModel
    @ObservedObject var source: AudioToolKit.Source
    @ObservedObject var player: AudioToolKit.Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dragging = false
    @State private var pulse = false

    private let corner: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let box = fitted(model.shape.aspect, in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.black)
                ZStack {
                    frame
                        .aspectRatio(model.shape.aspect, contentMode: .fit)
                        .id(model.shape)
                        .transition(.opacity)
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                overlay(width: box.width)
            }
            .frame(width: box.width, height: box.height)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .onHover { hovering = $0 }
            .gesture(gesture(width: box.width))
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video preview")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.togglePlay() }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func fitted(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }

    /// One frame of the video, redrawn every display frame while playing.
    private var frame: some View {
        let loading = source.levels == nil && source.failure == nil && model.style == .waveform
        return AudioToolKit.Live(active: player.isPlaying) {
            let count = Viz.count(for: model.shape)
            let values = barValues(count)
            let lit = model.lit(at: player.time, count: count)
            Canvas { context, size in
                Viz.paint(&context, size: size, style: model.style,
                          picture: model.usesPicture ? model.picture?.preview : nil, values: values, lit: lit)
            }
        }
        .opacity(loading ? (pulse ? 0.9 : 0.4) : 1)
    }

    private func barValues(_ count: Int) -> [Float] {
        guard source.failure == nil else { return Array(repeating: 0, count: count) }
        let peak = max(source.maxPeak, 0.01)
        return source.bars(count).map { min(1, $0 / peak) }
    }

    @ViewBuilder private func overlay(width: CGFloat) -> some View {
        if let failure = source.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
        } else {
            ZStack {
                if hovering && !dragging {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.16))
                        Circle()
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .offset(x: player.isPlaying ? 0 : 1.5)
                    }
                    .frame(width: 46, height: 46)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.85)))
                }
                if (hovering || dragging), source.info != nil {
                    AudioToolKit.Live(active: player.isPlaying) {
                        Text(source.clock(player.time) + " / " + source.clock(source.duration))
                            .font(ToolStyle.mono)
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.6), radius: 3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: hovering)
            .animation(.easeOut(duration: 0.16), value: dragging)
            .allowsHitTesting(false)
        }
    }

    private func gesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard source.failure == nil, source.duration > 0, width > 0 else { return }
                if dragging || abs(value.translation.width) >= 3 {
                    dragging = true
                    model.scrub(to: Double(min(1, max(0, value.location.x / width))) * source.duration)
                }
            }
            .onEnded { _ in
                if dragging {
                    dragging = false
                    model.endScrub()
                } else {
                    model.togglePlay()
                }
            }
    }
}

// MARK: - Rendering and export

extension AudioToolKit {
    enum Visualizer {
        enum Style: Hashable { case waveform, still }

        enum Shape: Hashable, CaseIterable {
            case landscape, portrait, square

            var title: String {
                switch self {
                case .landscape: "Landscape · 16:9"
                case .portrait: "Portrait · 9:16"
                case .square: "Square · 1:1"
                }
            }

            var pixels: (width: Int, height: Int) {
                switch self {
                case .landscape: (1920, 1080)
                case .portrait: (1080, 1920)
                case .square: (1080, 1080)
                }
            }

            var aspect: CGFloat { CGFloat(pixels.width) / CGFloat(pixels.height) }
        }

        /// A chosen picture: the file, and a smaller copy for the preview.
        struct Picture {
            let url: URL
            let preview: CGImage

            /// Short enough for a pop-up button.
            var shortName: String {
                let name = url.lastPathComponent
                guard name.count > 26 else { return name }
                return String(name.prefix(14)) + "…" + String(name.suffix(10))
            }
        }

        /// Everything the export needs from the window.
        struct Plan {
            var source: URL
            var style: Style
            var shape: Shape
            var picture: URL?
            /// Bar heights the window already worked out (0...1), if it finished reading the file.
            var values: [Float]?
            var duration: Double?
        }

        // Geometry measured from the original's 16:9 frame: 60 bars across, each about half
        // its pitch wide, the loudest reaching 77% of the height, silence drawn as dots.
        static let pitch: CGFloat = 0.028
        static let barShare: CGFloat = 0.48
        static let margin: CGFloat = 0.028
        static let band: CGFloat = 0.77
        static let dot: CGFloat = 1.2
        /// Bars still to come are drawn at this opacity.
        static let dim: Double = 0.38
        /// Darkening over a background picture, so the waveform stays readable.
        static let scrim: Double = 0.35
        static let fps = 30

        /// Bars across a frame of this shape. Depends only on the shape, so the preview and
        /// the 1080p video always have the same bars.
        static func count(for shape: Shape) -> Int {
            let w = max(shape.aspect, 1)
            let usable = w - 2 * margin * w - barShare * pitch
            return max(1, Int((usable / pitch).rounded(.down)) + 1)
        }

        /// Each bar's rect in a frame of `size`, centred both ways.
        static func bars(_ values: [Float], in size: CGSize) -> [CGRect] {
            let n = values.count
            guard n > 0, size.width > 0, size.height > 0 else { return [] }
            let s = min(size.width, size.height)
            let p = pitch * s
            let w = barShare * p
            let tallest = band * min(size.height, size.width * 9 / 16)
            let used = CGFloat(n - 1) * p + w
            let x0 = (size.width - used) / 2
            return values.enumerated().map { i, v in
                let h = max(dot * w, CGFloat(min(1, max(0, v))) * tallest)
                return CGRect(x: x0 + CGFloat(i) * p, y: (size.height - h) / 2, width: w, height: h)
            }
        }

        /// Loudest peak per bar, scaled so the loudest bar is full height.
        static func values(_ levels: Levels, count: Int) -> [Float] {
            let peak = max(levels.maxPeak, 0.01)
            return levels.bars(count, from: 0, to: levels.duration).map { min(1, $0 / peak) }
        }

        /// A bar lights up as the playhead passes its middle.
        static func lit(time: Double, duration: Double, count: Int) -> Int {
            guard duration > 0 else { return 0 }
            return min(count, max(0, Int((time / duration * Double(count) + 0.5).rounded(.down))))
        }

        static func fill(_ image: CGSize, into size: CGSize) -> CGRect {
            guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: size) }
            let k = max(size.width / image.width, size.height / image.height)
            let w = image.width * k
            let h = image.height * k
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }

        static func fit(_ image: CGSize, into size: CGSize) -> CGRect {
            guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: size) }
            let k = min(size.width / image.width, size.height / image.height)
            let w = image.width * k
            let h = image.height * k
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }

        /// The preview: the same drawing as `draw(in:)`, in a SwiftUI canvas.
        static func paint(_ context: inout GraphicsContext, size: CGSize, style: Style, picture: CGImage?,
                          values: [Float], lit: Int?) {
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(.black))
            if let picture {
                let image = Image(decorative: picture, scale: 1)
                let natural = CGSize(width: picture.width, height: picture.height)
                if style == .still {
                    context.draw(image, in: fit(natural, into: size))
                    return
                }
                context.clip(to: Path(rect))
                context.draw(image, in: fill(natural, into: size))
                context.fill(Path(rect), with: .color(.black.opacity(scrim)))
            } else if style == .still {
                return
            }
            for (i, r) in bars(values, in: size).enumerated() {
                let on = lit.map { i < $0 } ?? true
                context.fill(Path(roundedRect: r, cornerRadius: r.width / 2),
                             with: .color(on ? ToolStyle.orange : ToolStyle.orange.opacity(dim)))
            }
        }

        /// One video frame in Core Graphics.
        static func draw(in cg: CGContext, size: CGSize, style: Style, picture: CGImage?, values: [Float], lit: Int?) {
            let rect = CGRect(origin: .zero, size: size)
            cg.setFillColor(CGColor(gray: 0, alpha: 1))
            cg.fill(rect)
            cg.interpolationQuality = .high
            if let picture {
                let natural = CGSize(width: picture.width, height: picture.height)
                if style == .still {
                    cg.draw(picture, in: fit(natural, into: size))
                    return
                }
                cg.saveGState()
                cg.clip(to: rect)
                cg.draw(picture, in: fill(natural, into: size))
                cg.restoreGState()
                cg.setFillColor(CGColor(gray: 0, alpha: scrim))
                cg.fill(rect)
            } else if style == .still {
                return
            }
            let orange = ToolStyle.nsOrange.cgColor
            let faded = orange.copy(alpha: dim) ?? orange
            for (i, r) in bars(values, in: size).enumerated() {
                let on = lit.map { i < $0 } ?? true
                cg.setFillColor(on ? orange : faded)
                let radius = r.width / 2
                cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: min(radius, r.height / 2), transform: nil))
                cg.fillPath()
            }
        }

        /// Reads a picture with its orientation applied, no bigger than `maxPixels` on its long side.
        static func loadPicture(_ url: URL, maxPixels: Int) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        private static func writeFrame(_ url: URL, size: (width: Int, height: Int), style: Style,
                                       picture: CGImage?, values: [Float], lit: Int?) throws {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw JobError.failed("Couldn't draw the video.") }
            draw(in: cg, size: CGSize(width: size.width, height: size.height), style: style,
                 picture: picture, values: values, lit: lit)
            guard let image = cg.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw JobError.failed("Couldn't draw the video.") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw JobError.failed("Couldn't draw the video.") }
        }

        /// The waveform only changes when a bar lights up, so each distinct frame is drawn once
        /// and held for as long as it's on screen; ffmpeg turns that into steady 30 fps H.264.
        static func run(_ src: URL, to out: URL, plan: Plan, ctx: JobContext) throws {
            let info = try AudioToolKit.probe(src, ctx: ctx)
            let size = plan.shape.pixels
            var picture: CGImage?
            if let url = plan.picture {
                guard let image = loadPicture(url, maxPixels: 2 * max(size.width, size.height)) else {
                    throw JobError.failed("Couldn't open the picture.")
                }
                picture = image
            }
            let n = count(for: plan.shape)
            var duration = plan.source == src ? (plan.duration ?? info.duration) : info.duration
            var values: [Float] = []
            if plan.style == .waveform {
                if plan.source == src, let ready = plan.values, ready.count == n {
                    values = ready
                } else {
                    let levels = try AudioToolKit.decodeLevels(src, info: info, ctx: ctx)
                    values = Self.values(levels, count: n)
                    duration = levels.duration
                }
            }
            guard duration > 0 else { throw JobError.failed("This file has no sound.") }
            ctx.progress(0.02)

            let folder = try ctx.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let states: [Int?] = plan.style == .waveform ? (0...n).map { $0 } : [nil]
            func name(_ k: Int) -> String { String(format: "frame%04d.png", k) }

            // Each frame is independent and PNG encoding is the slow part, so a few draw at once.
            let lanes = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
            let drawn = AudioToolKit.Locked(0)
            let failure = AudioToolKit.Locked<Error?>(nil)
            let style = plan.style
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for k in stride(from: lane, to: states.count, by: lanes) {
                    guard failure.value == nil, !ctx.isCancelled else { return }
                    do {
                        try writeFrame(folder.appendingPathComponent(name(k)), size: size, style: style,
                                       picture: picture, values: values, lit: states[k])
                    } catch {
                        failure.mutate { if $0 == nil { $0 = error } }
                        return
                    }
                    let count = drawn.mutate { value -> Int in
                        value += 1
                        return value
                    }
                    ctx.progress(0.02 + 0.06 * Double(count) / Double(states.count))
                }
            }
            try ctx.checkCancelled()
            if let error = failure.value { throw error }

            let step = duration / Double(n)
            var list = "ffconcat version 1.0\n"
            for k in states.indices {
                let hold: Double
                if states.count == 1 {
                    hold = duration + 1
                } else if k == 0 {
                    hold = step / 2
                } else if k == n {
                    hold = step / 2 + 1
                } else {
                    hold = step
                }
                list += "file '\(name(k))'\nduration \(String(format: "%.6f", hold))\n"
            }
            // The concat reader only honours the last duration when the file is listed again.
            list += "file '\(name(states.count - 1))'\n"
            let listURL = folder.appendingPathComponent("frames.ffconcat")
            try list.write(to: listURL, atomically: true, encoding: .utf8)

            let length = String(format: "%.6f", duration)
            var args = ["-f", "concat", "-safe", "0", "-i", listURL.path, "-i", src.path,
                        "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "1",
                        // Convert the few distinct frames first, then repeat them up to 30 fps.
                        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,fps=\(fps)",
                        "-c:v", "libx264", "-preset", duration > 600 ? "ultrafast" : "veryfast",
                        "-tune", "stillimage", "-crf", "20", "-pix_fmt", "yuv420p",
                        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                        "-c:a", "aac", "-b:a", "192k"]
            if info.channels > 2 { args += ["-ac", "2"] }
            args += ["-t", length, "-shortest", "-movflags", "+faststart", out.path]
            try MediaEngine.ffmpeg(args, duration: duration, ctx: ctx, progressRange: 0.08...1)
        }
    }
}
