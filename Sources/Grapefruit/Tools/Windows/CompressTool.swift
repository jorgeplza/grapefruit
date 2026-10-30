import Accelerate
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Measured from the original: a 380pt window, small native controls, a 12pt medium size
// line, a 13pt bold section title and 10pt grey captions. The space under the checkbox is
// always there, so ticking it never resizes the window.
struct CompressTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: CompressModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: CompressModel(urls: session.urls))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: 380, onClose: session.close) {
            VStack(alignment: .leading, spacing: 0) {
                FileToolKit.FileLine(urls: session.urls)
                sizeRow
                    .padding(.top, 19)
                if model.showsPresets {
                    presetSection
                        .padding(.top, 19)
                } else {
                    Text(model.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(ToolStyle.secondary)
                        .padding(.top, 12)
                }
                if model.showsResize {
                    resizeRow
                        .padding(.top, 12)
                }
                if model.showsTarget {
                    Divider()
                        .padding(.top, 16)
                    targetSection
                        .padding(.top, 16)
                }
            }
            .controlSize(.small)
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Compress", primaryEnabled: model.canCompress, onPrimary: compress)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.targetOn) { _, on in fieldFocused = on }
    }

    // MARK: Rows

    private var sizeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Original size: \(FileToolKit.bytes(model.totalSize))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(model.sideNote.text)
                .font(.system(size: 11))
                .foregroundStyle(model.sideNote.isError ? AnyShapeStyle(ToastStyle.failure) : AnyShapeStyle(ToolStyle.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
                .contentTransition(.opacity)
                .animation(FileToolKit.motion(reduceMotion), value: model.sideNote)
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compression preset")
                .font(.system(size: 13, weight: .bold))
            Picker("", selection: $model.preset) {
                Text("Balanced").tag(FileToolKit.Preset.balanced)
                Text("Strong").tag(FileToolKit.Preset.strong)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.targetOn)
            .padding(.top, 12)
            Text(model.targetOn ? "Quality adjusts to hit your target size." : model.caption)
                .font(.system(size: 10))
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(FileToolKit.motion(reduceMotion), value: model.preset)
                .animation(FileToolKit.motion(reduceMotion), value: model.targetOn)
                .padding(.top, 11)
        }
    }

    private var resizeRow: some View {
        HStack(spacing: 10) {
            Text(model.kind == .video ? "Video size" : "Image size")
                .font(.system(size: 13))
            Picker("", selection: $model.resize) {
                ForEach(model.resizeOptions, id: \.self) { option in
                    Text(model.label(for: option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(model.resizeOptions.count < 2)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.targetOn.animation(FileToolKit.motion(reduceMotion))) {
                Text("Compress to target file size")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                TextField("", text: $model.targetText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .focused($fieldFocused)
                Picker("", selection: $model.targetUnit) {
                    ForEach(CompressModel.Unit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Text(model.targetHint.text)
                    .font(.system(size: 10))
                    .foregroundStyle(model.targetHint.isError ? AnyShapeStyle(ToastStyle.failure) : AnyShapeStyle(ToolStyle.secondary))
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .contentTransition(.opacity)
                    .animation(FileToolKit.motion(reduceMotion), value: model.targetHint)
            }
            .padding(.leading, 20)
            .opacity(model.targetOn ? 1 : 0)
            .offset(y: model.targetOn || reduceMotion ? 0 : -4)
            .allowsHitTesting(model.targetOn)
            .accessibilityHidden(!model.targetOn)
        }
        .padding(.bottom, 12)
    }

    private func compress() {
        guard model.canCompress else { return }
        let settings = model.settings
        model.stop()
        session.runEach(ext: { FileToolKit.Compressor.outputExtension(for: $0) }) { src, out, ctx in
            try FileToolKit.Compressor.run(src, to: out, settings, ctx: ctx)
        }
    }
}

// MARK: - Model

@MainActor
private final class CompressModel: ObservableObject {
    enum Unit: String, CaseIterable {
        case mb, kb, percent

        var title: String {
            switch self {
            case .mb: "MB"
            case .kb: "KB"
            case .percent: "%"
            }
        }
    }

    struct Note: Equatable {
        var text = ""
        var isError = false
    }

    private enum Estimate {
        case size(Int64)
        case failed(String)
    }

    let urls: [URL]
    let kind: FileToolKit.Kind
    let formats: Set<String>
    let totalSize: Int64

    @Published var preset = FileToolKit.Preset.balanced { didSet { scheduleEstimate() } }
    @Published var resize = FileToolKit.Resize.original { didSet { scheduleEstimate() } }
    @Published var targetOn = false { didSet { scheduleEstimate() } }
    @Published var targetText: String
    @Published var targetUnit: Unit
    @Published private(set) var sideNote = Note()
    @Published private(set) var pixelSize: (width: Int, height: Int)?
    @Published private(set) var videoSize: (width: Int, height: Int)?
    @Published private(set) var readError: String?

    private var estimates: [String: Estimate] = [:]
    private var estimateTask: Task<Void, Never>?
    private var estimateContext: JobContext?
    private var started = false
    private var stopped = false

    init(urls: [URL]) {
        self.urls = urls
        kind = urls.first.map { FileToolKit.kind(of: $0) } ?? .other
        formats = Set(urls.map { FileToolKit.format(of: $0) })
        totalSize = urls.reduce(Int64(0)) { $0 + FileToolKit.fileSize($1) }
        if urls.count == 1, totalSize > 0 {
            // Half the original is a sensible first guess.
            let half = Double(totalSize) / 2
            if half >= 1_000_000 {
                targetText = Self.trimmed(half / 1_000_000)
                targetUnit = .mb
            } else {
                targetText = String(Int(max(1, (half / 1000).rounded())))
                targetUnit = .kb
            }
        } else {
            targetText = "50"
            targetUnit = .percent
        }
    }

    // MARK: What the window shows

    private static let losslessAudio: Set<String> = ["wav", "flac", "aiff"]

    var allLosslessAudio: Bool { kind == .audio && formats.isSubset(of: Self.losslessAudio) }
    var showsPresets: Bool { !allLosslessAudio }
    var showsResize: Bool { kind == .image || kind == .video }
    var showsTarget: Bool {
        switch kind {
        case .image, .video: return true
        case .audio: return formats.isDisjoint(with: Self.losslessAudio)
        default: return false
        }
    }

    var caption: String {
        switch kind {
        case .image where formats == ["png"]:
            return preset == .balanced ? "Lossless. Same pixels, smaller file." : "Fewer colors for a much smaller file."
        case .pdf:
            return preset == .balanced ? "Recompresses images at full resolution." : "Shrinks images for reading on screen."
        case .audio where allLosslessAudio:
            return formats == ["flac"] ? "Repacks at maximum FLAC compression. Sounds exactly the same."
                : "Saves as lossless FLAC. Sounds exactly the same."
        default:
            return preset == .balanced ? "Smaller files with less quality loss." : "Smallest files with more quality loss."
        }
    }

    var resizeOptions: [FileToolKit.Resize] {
        guard kind == .video else { return [.original, .percent(75), .percent(50), .percent(25)] }
        let all: [FileToolKit.Resize] = [.original, .shortSide(1080), .shortSide(720), .shortSide(480)]
        guard let size = videoSize else { return all }
        // Only sizes that are actually smaller than the video.
        return all.filter {
            if case .shortSide(let side) = $0 { return side < min(size.width, size.height) }
            return true
        }
    }

    func label(for option: FileToolKit.Resize) -> String {
        switch option {
        case .original:
            return "Keep original dimensions"
        case .percent(let p):
            guard let size = pixelSize else { return "\(p)%" }
            let w = max(1, Int((Double(size.width) * Double(p) / 100).rounded()))
            let h = max(1, Int((Double(size.height) * Double(p) / 100).rounded()))
            return "\(p)% (\(w) × \(h))"
        case .shortSide(let side):
            guard let size = videoSize, size.width > 0, size.height > 0 else { return "\(side)p" }
            let scale = Double(side) / Double(min(size.width, size.height))
            let w = Int((Double(size.width) * scale / 2).rounded()) * 2
            let h = Int((Double(size.height) * scale / 2).rounded()) * 2
            return "\(side)p (\(w) × \(h))"
        }
    }

    // MARK: Target size

    var targetValue: Double? {
        let cleaned = targetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v.isFinite, v > 0 else { return nil }
        return v
    }

    var target: FileToolKit.Target? {
        guard targetOn, let v = targetValue else { return nil }
        switch targetUnit {
        case .mb: return .bytes(Int64(v * 1_000_000))
        case .kb: return .bytes(Int64(v * 1000))
        case .percent: return .percent(v)
        }
    }

    var targetHint: Note {
        guard let v = targetValue else { return Note(text: "Type a size", isError: true) }
        switch targetUnit {
        case .percent:
            guard v >= 1, v < 100 else { return Note(text: "Pick 1 to 99%", isError: true) }
            if urls.count == 1 { return Note(text: "About \(FileToolKit.bytes(Int64(Double(totalSize) * v / 100)))") }
            return Note(text: "Of each file")
        case .mb, .kb:
            let bytes = Int64(v * (targetUnit == .mb ? 1_000_000 : 1000))
            guard bytes >= 4000 else { return Note(text: "Too small", isError: true) }
            guard urls.count == 1 else { return Note(text: "For each file") }
            if bytes >= totalSize { return Note(text: "Pick less than \(FileToolKit.bytes(totalSize))", isError: true) }
            let share = max(1, Int((Double(bytes) / Double(max(1, totalSize)) * 100).rounded()))
            return Note(text: "\(share)% of the original")
        }
    }

    var settings: FileToolKit.CompressSettings {
        FileToolKit.CompressSettings(preset: preset, resize: resize, target: target)
    }

    var canCompress: Bool {
        guard !urls.isEmpty, readError == nil else { return false }
        if targetOn && (targetHint.isError || target == nil) { return false }
        guard kind == .image, urls.count == 1, !targetOn else { return true }
        switch estimates[estimateKey] {
        case .size(let size): return size < totalSize
        case .failed: return false
        case nil: return true
        }
    }

    // MARK: Loading and estimates

    func start() {
        guard !started else { return }
        started = true
        stopped = false
        guard urls.count == 1, let url = urls.first else { return }
        switch kind {
        case .image:
            sideNote = Note(text: "Estimating…")
            FileToolKit.background({ FileToolKit.Compressor.pixelSize(url) }) { [weak self] size in
                guard let self, !self.stopped else { return }
                if let size {
                    self.pixelSize = size
                    self.scheduleEstimate(delay: 0)
                } else {
                    self.fail("Couldn't read this file.")
                }
            }
        case .video, .audio:
            FileToolKit.background({ try? FileToolKit.probeMedia(url) }) { [weak self] info in
                guard let self, !self.stopped else { return }
                guard let info, self.kind == .video ? info.video != nil : !info.audio.isEmpty else {
                    self.fail("Couldn't read this file.")
                    return
                }
                if self.kind == .video {
                    self.videoSize = info.displaySize
                    if !self.resizeOptions.contains(self.resize) { self.resize = .original }
                }
            }
        case .pdf:
            FileToolKit.background({ () -> String? in
                do {
                    _ = try PDFEngine.open(url)
                    return nil
                } catch {
                    return JobCenter.describe(error)
                }
            }) { [weak self] message in
                guard let self, !self.stopped, let message else { return }
                self.fail(message)
            }
        default:
            break
        }
    }

    func stop() {
        stopped = true
        estimateTask?.cancel()
        estimateContext?.cancel()
    }

    private func fail(_ message: String) {
        readError = message
        sideNote = Note(text: message, isError: true)
    }

    private var estimateKey: String { "\(preset.rawValue)-\(resize)" }

    /// One photo gets a real estimate: the same encode the job runs, in the background, thrown away.
    private func scheduleEstimate(delay: Double = 0.25) {
        guard kind == .image, urls.count == 1, let url = urls.first, started, !stopped,
              readError == nil, pixelSize != nil else { return }
        estimateTask?.cancel()
        estimateContext?.cancel()
        estimateContext = nil
        if targetOn {
            sideNote = Note()
            return
        }
        let key = estimateKey
        if let known = estimates[key] {
            sideNote = note(for: known)
            return
        }
        sideNote = Note(text: "Estimating…")
        let settings = FileToolKit.CompressSettings(preset: preset, resize: resize, target: nil)
        estimateTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled, !self.stopped else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("grapefruit-estimate-\(UUID().uuidString)")
            let scratch = folder.appendingPathComponent("out")
            let ctx = JobContext(scratch: scratch) { _ in }
            self.estimateContext = ctx
            FileToolKit.background({ () -> Estimate? in
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    return .size(try FileToolKit.Compressor.estimate(url, settings, ctx: ctx))
                } catch JobError.cancelled {
                    return nil
                } catch {
                    return ctx.isCancelled ? nil : .failed(JobCenter.describe(error))
                }
            }) { [weak self] result in
                guard let self, let result, !ctx.isCancelled else { return }
                self.estimates[key] = result
                guard !self.stopped, key == self.estimateKey, !self.targetOn else { return }
                self.sideNote = self.note(for: result)
            }
        }
    }

    private func note(for estimate: Estimate) -> Note {
        switch estimate {
        case .size(let size):
            return size >= totalSize ? Note(text: "Already as small as it gets") : Note(text: "About \(FileToolKit.bytes(size))")
        case .failed(let message):
            return Note(text: message, isError: true)
        }
    }

    static func trimmed(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

// MARK: - Settings

extension FileToolKit {
    enum Preset: String, Sendable {
        case balanced, strong
    }

    enum Resize: Hashable, Sendable {
        case original
        /// Photos: a share of each side.
        case percent(Int)
        /// Video: the short side, so portrait clips shrink the same way as landscape ones.
        case shortSide(Int)
    }

    enum Target: Hashable, Sendable {
        case bytes(Int64)
        case percent(Double)

        func bytes(for original: Int64) -> Int64 {
            switch self {
            case .bytes(let b): return b
            case .percent(let p): return Int64(Double(original) * p / 100)
            }
        }
    }

    struct CompressSettings: Sendable {
        var preset = Preset.balanced
        var resize = Resize.original
        var target: Target?
    }
}

// MARK: - Engine

extension FileToolKit {
    enum Compressor {
        static func outputExtension(for src: URL) -> String {
            switch format(of: src) {
            case "wav", "aiff": return "flac"
            default: return src.pathExtension
            }
        }

        /// Compresses `src` into `out`. Never leaves something bigger than the original.
        static func run(_ src: URL, to out: URL, _ s: CompressSettings, ctx: JobContext) throws {
            let original = fileSize(src)
            let target = s.target.map { $0.bytes(for: original) }
            if let target, target >= original {
                throw JobError.failed("Already under \(bytes(target)).")
            }
            let fileKind = kind(of: src)
            switch fileKind {
            case .image:
                let data = try image(src, s, target: target, ctx: ctx)
                try ctx.checkCancelled()
                guard Int64(data.count) < original else { throw JobError.failed("Already as small as it gets.") }
                try data.write(to: out)
            case .video:
                try video(src, to: out, s, target: target, ctx: ctx)
            case .audio:
                try audio(src, to: out, s, target: target, ctx: ctx)
            case .pdf:
                try pdf(src, to: out, s, ctx: ctx)
            case .other:
                throw JobError.failed("Can't compress this kind of file.")
            }
            try ctx.checkCancelled()
            if fileKind != .image, fileSize(out) >= original {
                try? FileManager.default.removeItem(at: out)
                throw JobError.failed("Already as small as it gets.")
            }
            ctx.progress(1)
        }

        /// The size one photo ends up at with these settings: the real encode, thrown away.
        static func estimate(_ src: URL, _ s: CompressSettings, ctx: JobContext) throws -> Int64 {
            Int64(try image(src, s, target: nil, ctx: ctx).count)
        }

        /// Pixel size as shown (after EXIF rotation), read without decoding.
        static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0 else { return nil }
            let o = props[kCGImagePropertyOrientation] as? Int ?? 1
            return o >= 5 ? (h, w) : (w, h)
        }

        // MARK: Encoders on this Mac

        private static let encoders: String = {
            guard let ffmpeg = Binaries.ffmpeg,
                  let result = try? Shell.run(ffmpeg, ["-hide_banner", "-encoders"], timeout: 20) else { return "" }
            return String(decoding: result.stdout, as: UTF8.self)
        }()

        static func hasEncoder(_ name: String) -> Bool {
            encoders.contains(" \(name) ")
        }

        static var aacEncoder: String { hasEncoder("aac_at") ? "aac_at" : "aac" }

        // MARK: Images

        static func image(_ src: URL, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws -> Data {
            let f = format(of: src)
            switch f {
            case "png": return try Squeeze.png(src, s, target: target, ctx: ctx)
            case "webp": return try webp(src, s, target: target, ctx: ctx)
            case "tiff": return try tiff(src, s, target: target, ctx: ctx)
            case "jpg", "heic", "avif": return try lossy(src, f, s, target: target, ctx: ctx)
            default: throw JobError.failed("Can't compress \(f.uppercased()) images.")
            }
        }

        static func quality(_ f: String, _ p: Preset) -> Double {
            switch (f, p) {
            case ("heic", .balanced): return 0.6
            case ("heic", .strong): return 0.45
            case ("avif", .balanced): return 0.72
            case ("avif", .strong): return 0.6
            case (_, .balanced): return 0.72
            case (_, .strong): return 0.5
            }
        }

        static func scaled(_ image: CGImage, _ r: Resize) -> CGImage {
            guard case .percent(let p) = r, p > 0, p < 100 else { return image }
            let w = max(1, Int((Double(image.width) * Double(p) / 100).rounded()))
            let h = max(1, Int((Double(image.height) * Double(p) / 100).rounded()))
            return ImageEngine.resized(image, width: w, height: h)
        }

        static func setPixelSize(_ props: inout [CFString: Any], _ w: Int, _ h: Int) {
            guard var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return }
            exif[kCGImagePropertyExifPixelXDimension] = w
            exif[kCGImagePropertyExifPixelYDimension] = h
            props[kCGImagePropertyExifDictionary] = exif
        }

        /// JPEG, HEIC, AVIF: ImageIO at a preset quality, or the best quality that fits the target.
        /// EXIF, GPS and the colour profile come along.
        static func lossy(_ src: URL, _ f: String, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws -> Data {
            let loaded = try ImageEngine.load(src, format: f)
            try ctx.checkCancelled()
            ctx.progress(0.15)
            var picture = scaled(loaded.image, s.resize)
            if f == "jpg" { picture = ImageEngine.flattened(picture) }
            guard let type = ImageEngine.utTypes[f] else { throw JobError.failed("Can't write \(f.uppercased()) images.") }
            let props = loaded.properties
            let encode: (CGImage, Double) throws -> Data = { image, q in
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                    throw JobError.failed("Can't write \(f.uppercased()) on this Mac.")
                }
                var p = props
                p[kCGImageDestinationLossyCompressionQuality] = q
                setPixelSize(&p, image.width, image.height)
                CGImageDestinationAddImage(dest, image, p as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw JobError.failed("Couldn't save the \(f.uppercased()) file.") }
                return data as Data
            }
            guard let target else {
                let data = try encode(picture, quality(f, s.preset))
                ctx.progress(0.95)
                return data
            }
            var smaller: CGImage?
            return try fit(width: picture.width, height: picture.height, target: target, ctx: ctx) { w, h, q in
                if w == picture.width && h == picture.height { return try encode(picture, q) }
                if smaller?.width != w || smaller?.height != h { smaller = ImageEngine.resized(picture, width: w, height: h) }
                return try encode(smaller ?? picture, q)
            }
        }

        /// The highest quality that lands under `target`, found in a few encodes by reading the
        /// size curve between the two closest tries. When even a low quality is too big, the
        /// picture gets smaller before the quality drops any further.
        static func fit(width: Int, height: Int, target: Int64, ctx: JobContext, qualities: ClosedRange<Double> = 0.1...0.92,
                        encode: (Int, Int, Double) throws -> Data) throws -> Data {
            var w = width, h = height
            for round in 0..<8 {
                try ctx.checkCancelled()
                let top = try encode(w, h, qualities.upperBound)
                if top.count <= target { return top }
                // Big pictures shrink before they get blocky.
                let floor = max(w, h) > 1400 ? max(qualities.lowerBound, 0.35) : qualities.lowerBound
                let bottom = try encode(w, h, floor)
                ctx.progress(min(0.85, 0.25 + Double(round) * 0.1))
                if bottom.count <= target {
                    var fits = (q: floor, data: bottom)
                    var over = (q: qualities.upperBound, data: top)
                    for _ in 0..<5 where over.q - fits.q > 0.015 {
                        try ctx.checkCancelled()
                        let low = log(Double(fits.data.count)), high = log(Double(over.data.count))
                        let t = high > low ? (log(Double(target)) - low) / (high - low) : 0.5
                        let q = fits.q + min(0.85, max(0.15, t)) * (over.q - fits.q)
                        let d = try encode(w, h, q)
                        if d.count <= target {
                            fits = (q, d)
                        } else {
                            over = (q, d)
                        }
                    }
                    return fits.data
                }
                let scale = max(0.35, min(0.9, (Double(target) / Double(bottom.count)).squareRoot() * 0.97))
                w = Int(Double(w) * scale)
                h = Int(Double(h) * scale)
                guard w >= 16, h >= 16 else { break }
            }
            throw JobError.failed("Couldn't get this file that small.")
        }

        /// WebP through cwebp, keeping its EXIF, XMP and colour profile.
        static func webp(_ src: URL, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws -> Data {
            let bytes = [UInt8](try Data(contentsOf: src))
            guard bytes.count > 30, Array(bytes[0..<4]) == Bytes.ascii("RIFF"), Array(bytes[8..<12]) == Bytes.ascii("WEBP") else {
                throw JobError.failed("Couldn't read this WebP.")
            }
            if Array(bytes[12..<16]) == Bytes.ascii("VP8X"), bytes[20] & 0x02 != 0 {
                throw JobError.failed("Animated WebP can't be compressed yet.")
            }
            // Stored size: cwebp scales the stored pixels and leaves the EXIF rotation alone.
            guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let storedW = props[kCGImagePropertyPixelWidth] as? Int, let storedH = props[kCGImagePropertyPixelHeight] as? Int else {
                throw JobError.failed("Couldn't read this WebP.")
            }
            var w = storedW, h = storedH
            if case .percent(let p) = s.resize, p < 100 {
                w = max(1, storedW * p / 100)
                h = max(1, storedH * p / 100)
            }
            let temp = try ctx.temporaryFolder().appendingPathComponent("out.webp")
            guard let cwebp = Binaries.cwebp else {
                // No cwebp: ffmpeg's encoder still works, without the metadata.
                var picture = try ImageEngine.load(src, format: "webp").image
                if case .percent = s.resize { picture = scaled(picture, s.resize) }
                let encode: (CGImage, Double) throws -> Data = { image, q in
                    try ImageEngine.writeWebP(image, to: temp, quality: q, ctx: ctx)
                    return try Data(contentsOf: temp)
                }
                guard let target else { return try encode(picture, s.preset == .balanced ? 0.75 : 0.55) }
                var smaller: CGImage?
                return try fit(width: picture.width, height: picture.height, target: target, ctx: ctx, qualities: 0.05...0.9) { w, h, q in
                    if w == picture.width && h == picture.height { return try encode(picture, q) }
                    if smaller?.width != w || smaller?.height != h { smaller = ImageEngine.resized(picture, width: w, height: h) }
                    return try encode(smaller ?? picture, q)
                }
            }
            let encode: (Int, Int, Double) throws -> Data = { width, height, q in
                var args = ["-quiet", "-mt", "-q", String(Int((q * 100).rounded())), "-metadata", "all"]
                if width != storedW || height != storedH { args += ["-resize", String(width), String(height)] }
                try Shell.run(cwebp, args + [src.path, "-o", temp.path], ctx: ctx)
                return try Data(contentsOf: temp)
            }
            guard let target else {
                let data = try encode(w, h, s.preset == .balanced ? 0.75 : 0.55)
                ctx.progress(0.95)
                return data
            }
            return try fit(width: w, height: h, target: target, ctx: ctx, qualities: 0.05...0.9, encode: encode)
        }

        /// TIFF: lossless LZW for Balanced, JPEG inside the TIFF for Strong when there's no
        /// transparency. Every page and its metadata are kept.
        static func tiff(_ src: URL, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws -> Data {
            guard let source = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw JobError.failed("Couldn't read this TIFF.")
            }
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { throw JobError.failed("Couldn't read this TIFF.") }
            var pages: [(image: CGImage, props: [CFString: Any])] = []
            for i in 0..<count {
                try ctx.checkCancelled()
                guard let image = CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw JobError.failed("Couldn't decode this TIFF.")
                }
                let props = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]) ?? [:]
                pages.append((scaled(image, s.resize), props))
                ctx.progress(0.2 * Double(i + 1) / Double(count))
            }
            let canJPEG = pages.allSatisfy { page in
                let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(page.image.alphaInfo)
                return opaque && page.image.bitsPerComponent == 8 && [.rgb, .monochrome].contains(page.image.colorSpace?.model ?? .unknown)
            }
            let encode: (Int, Double?) throws -> Data = { compression, q in
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, pages.count, nil) else {
                    throw JobError.failed("Can't write TIFF on this Mac.")
                }
                for page in pages {
                    var p = page.props
                    var tiff = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                    tiff[kCGImagePropertyTIFFCompression] = compression
                    p[kCGImagePropertyTIFFDictionary] = tiff
                    p[kCGImagePropertyPixelWidth] = nil
                    p[kCGImagePropertyPixelHeight] = nil
                    if let q { p[kCGImageDestinationLossyCompressionQuality] = q }
                    setPixelSize(&p, page.image.width, page.image.height)
                    CGImageDestinationAddImage(dest, page.image, p as CFDictionary)
                }
                guard CGImageDestinationFinalize(dest) else { throw JobError.failed("Couldn't save the TIFF file.") }
                return data as Data
            }
            guard let target else {
                let data = s.preset == .strong && canJPEG ? try encode(7, 0.75) : try encode(5, nil)
                ctx.progress(0.95)
                return data
            }
            let lossless = try encode(5, nil)
            if lossless.count <= target { return lossless }
            guard canJPEG else { throw JobError.failed("Couldn't get this file that small.") }
            var lo = 0.1, hi = 0.92
            var found: Data?
            for step in 0..<7 {
                try ctx.checkCancelled()
                let mid = (lo + hi) / 2
                let d = try encode(7, mid)
                if d.count <= target {
                    found = d
                    lo = mid
                } else {
                    hi = mid
                }
                ctx.progress(0.3 + Double(step) * 0.09)
            }
            guard let found else { throw JobError.failed("Couldn't get this file that small.") }
            return found
        }

        // MARK: Video

        /// H.264 at a constant quality (two passes for a target size). HEVC and HDR stay HEVC on
        /// the hardware encoder so HDR survives. Sound, subtitles and tags come along.
        static func video(_ src: URL, to out: URL, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws {
            let info = try probeMedia(src, ctx: ctx)
            guard let v = info.video else { throw JobError.failed("This file has no video to compress.") }
            let quickTime = ["mp4", "mov", "m4v"].contains(src.pathExtension.lowercased())
            let tenBit = info.is10Bit || info.isHDR
            let keepHEVC = v.codec == "hevc" || info.isHDR
            let duration = max(info.duration, 0.1)

            // ffmpeg turns the picture upright when it re-encodes, so sizes are display sizes.
            let (dw, dh) = info.displaySize
            var outW = dw, outH = dh
            var filter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            if case .shortSide(let side) = s.resize, min(dw, dh) > side, dw > 0, dh > 0 {
                if dw >= dh {
                    filter = "scale=-2:\(side)"
                    outW = Int(Double(dw) * Double(side) / Double(dh))
                    outH = side
                } else {
                    filter = "scale=\(side):-2"
                    outW = side
                    outH = Int(Double(dh) * Double(side) / Double(dw))
                }
            }

            var audioRate: Int64 = s.preset == .balanced ? 128_000 : 96_000
            var videoRate: Int64?
            if let target {
                guard info.duration > 0 else { throw JobError.failed("Couldn't read how long this video is.") }
                let total = Double(target) * 8 * 0.96 / info.duration
                if total < 1_000_000 { audioRate = 96_000 }
                if total < 400_000 { audioRate = 64_000 }
                let rate = Int64(total) - (info.audio.isEmpty ? 0 : audioRate * Int64(info.audio.count))
                guard rate >= 100_000 else { throw JobError.failed("That size is too small for this video.") }
                videoRate = rate
            }

            var common = ["-i", src.path, "-map", "0:\(v.index)", "-map", "0:a?", "-map", "0:s?", "-dn",
                          "-map_metadata", "0", "-vf", filter]
            if !info.audio.isEmpty {
                let small = info.audio.allSatisfy { $0.codec == "aac" && $0.bitRate > 0 && $0.bitRate <= audioRate + audioRate / 10 }
                common += small ? ["-c:a", "copy"] : ["-c:a", aacEncoder, "-b:a", String(audioRate)]
            }
            common += ["-c:s", "copy"]
            var container: [String] = []
            if quickTime {
                let appleKeys = info.tags.contains { $0.key.hasPrefix("com.apple.quicktime.") }
                container += ["-movflags", appleKeys ? "+faststart+use_metadata_tags" : "+faststart"]
                if keepHEVC { container += ["-tag:v", "hvc1"] }
            }

            if keepHEVC {
                var color: [String] = []
                if !v.primaries.isEmpty && v.primaries != "unknown" { color += ["-color_primaries", v.primaries] }
                if !v.transfer.isEmpty && v.transfer != "unknown" { color += ["-color_trc", v.transfer] }
                if !v.matrix.isEmpty && v.matrix != "unknown" { color += ["-colorspace", v.matrix] }
                let pixelsPerSecond = Double(outW * outH) * max(v.fps, 24)
                let sourceRate = Double(info.videoBitRate) * Double(outW * outH) / Double(max(1, dw * dh))
                var rate: Double
                if let videoRate {
                    rate = Double(videoRate)
                } else {
                    let floor = pixelsPerSecond * (s.preset == .balanced ? 0.045 : 0.025) * (tenBit ? 1.25 : 1)
                    rate = max(floor, sourceRate * (s.preset == .balanced ? 0.5 : 0.3))
                    if sourceRate > 0 { rate = min(rate, sourceRate * 0.9) }
                }
                let hardware: (Double) -> [String] = { r in
                    ["-c:v", "hevc_videotoolbox", "-b:v", String(Int64(r)), "-profile:v", tenBit ? "main10" : "main",
                     "-pix_fmt", tenBit ? "p010le" : "yuv420p"] + color
                }
                if hasEncoder("hevc_videotoolbox") {
                    do {
                        try MediaEngine.ffmpeg(common + hardware(rate) + container + [out.path], duration: duration, ctx: ctx)
                        if let target, fileSize(out) > target {
                            let scale = Double(target) / Double(fileSize(out)) * 0.93
                            try? FileManager.default.removeItem(at: out)
                            try MediaEngine.ffmpeg(common + hardware(rate * scale) + container + [out.path], duration: duration, ctx: ctx)
                        }
                        return
                    } catch JobError.cancelled {
                        throw JobError.cancelled
                    } catch {
                        // The hardware encoder said no; x265 does the same job, slower.
                        try? FileManager.default.removeItem(at: out)
                    }
                }
                var software = ["-c:v", "libx265", "-preset", "fast", "-x265-params", "log-level=error",
                                "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p"] + color
                software += videoRate.map { ["-b:v", String($0)] } ?? ["-crf", s.preset == .balanced ? "26" : "30"]
                try MediaEngine.ffmpeg(common + software + container + [out.path], duration: duration, ctx: ctx)
                return
            }

            let x264 = ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-profile:v", "high"]
            guard let target, let videoRate else {
                let crf = s.preset == .balanced ? "23" : "28"
                try MediaEngine.ffmpeg(common + x264 + ["-crf", crf] + container + [out.path], duration: duration, ctx: ctx)
                return
            }
            let log = try ctx.temporaryFolder().appendingPathComponent("pass").path
            let twoPass: (Int64) throws -> Void = { rate in
                let bitrate = String(rate)
                let first = ["-i", src.path, "-map", "0:\(v.index)", "-vf", filter] + x264
                    + ["-b:v", bitrate, "-pass", "1", "-passlogfile", log, "-an", "-sn", "-dn", "-f", "null", "-"]
                try MediaEngine.ffmpeg(first, duration: duration, ctx: ctx, progressRange: 0...0.4)
                try MediaEngine.ffmpeg(common + x264 + ["-b:v", bitrate, "-pass", "2", "-passlogfile", log] + container + [out.path],
                                       duration: duration, ctx: ctx, progressRange: 0.4...1)
            }
            try twoPass(videoRate)
            let size = fileSize(out)
            if size > target {
                try? FileManager.default.removeItem(at: out)
                try twoPass(Int64(Double(videoRate) * Double(target) / Double(size) * 0.95))
            }
        }

        // MARK: Audio

        static let audioSteps: [Int64] = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320].map { $0 * 1000 }

        /// The largest standard bit rate at or under `rate`.
        static func step(_ rate: Int64) -> Int64 {
            audioSteps.last { $0 <= rate } ?? audioSteps[0]
        }

        /// MP3 and AAC get a lighter encode; WAV and AIFF become lossless FLAC; FLAC is repacked at
        /// its strongest level. Tags and cover art stay.
        static func audio(_ src: URL, to out: URL, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws {
            let info = try probeMedia(src, ctx: ctx)
            guard let a = info.audio.first else { throw JobError.failed("This file has no sound to compress.") }
            let f = format(of: src)
            let sourceRate = a.bitRate > 0 ? a.bitRate : info.bitRate
            var args = ["-i", src.path, "-map", "0:\(a.index)"]
            if ["mp3", "m4a", "flac"].contains(f), !info.covers.isEmpty {
                for cover in info.covers { args += ["-map", "0:\(cover.index)"] }
                args += ["-c:v", "copy"]
                if f == "m4a" { args += ["-disposition:v", "attached_pic"] }
            }
            args += ["-map_metadata", "0"]

            var targetRate: Int64?
            if let target {
                guard info.duration > 0 else { throw JobError.failed("Couldn't read how long this file is.") }
                let rate = Int64(Double(target) * 8 * 0.97 / info.duration)
                guard rate >= 32_000 else { throw JobError.failed("That size is too small for this file.") }
                targetRate = step(min(rate, 320_000))
            }
            // A lighter version of what's there: never more bits than the source had.
            let share = s.preset == .balanced ? 0.75 : 0.5
            func lighter(_ preset: Int64) -> Int64 {
                guard sourceRate > 0 else { return preset }
                return step(max(32_000, min(preset, Int64(Double(sourceRate) * share))))
            }
            switch f {
            case "mp3":
                args += ["-c:a", "libmp3lame"]
                if let r = targetRate {
                    args += ["-b:a", String(r)]
                } else if sourceRate == 0 || sourceRate >= 200_000 {
                    args += ["-q:a", s.preset == .balanced ? "4" : "6"]
                } else {
                    args += ["-b:a", String(lighter(s.preset == .balanced ? 128_000 : 96_000)), "-abr", "1"]
                }
                args += ["-id3v2_version", "3"]
            case "m4a":
                args += ["-c:a", aacEncoder, "-b:a", String(targetRate ?? lighter(s.preset == .balanced ? 128_000 : 96_000))]
            case "wav", "aiff", "flac":
                args += ["-c:a", "flac", "-compression_level", "12"]
            default:
                throw JobError.failed("Can't compress \(f.uppercased()) files yet.")
            }
            try MediaEngine.ffmpeg(args + [out.path], duration: info.duration, ctx: ctx)
        }

        // MARK: PDF

        /// Saves the images inside as JPEG (and smaller, for screens, on Strong). The pages go
        /// into a fresh document first, otherwise PDFKit writes the original bytes back untouched.
        static func pdf(_ src: URL, to out: URL, _ s: CompressSettings, ctx: JobContext) throws {
            let doc = try PDFEngine.open(src)
            let fresh = PDFDocument()
            for i in 0..<doc.pageCount {
                try ctx.checkCancelled()
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                fresh.insert(page, at: fresh.pageCount)
                ctx.progress(0.3 * Double(i + 1) / Double(doc.pageCount))
            }
            guard fresh.pageCount == doc.pageCount else { throw JobError.failed("Couldn't read every page of this PDF.") }
            fresh.documentAttributes = doc.documentAttributes
            if let root = doc.outlineRoot {
                let copy = PDFOutline()
                cloneOutline(root, into: copy, from: doc, to: fresh)
                fresh.outlineRoot = copy
            }
            var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if s.preset == .strong { options[.optimizeImagesForScreenOption] = true }
            ctx.progress(0.4)
            try ctx.checkCancelled()
            guard fresh.write(to: out, withOptions: options) else { throw JobError.failed("Couldn't save the PDF.") }
        }

        static func cloneOutline(_ node: PDFOutline, into parent: PDFOutline, from src: PDFDocument, to dst: PDFDocument) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let copy = PDFOutline()
                copy.label = child.label
                if let destination = child.destination, let page = destination.page {
                    if let newPage = dst.page(at: src.index(for: page)) {
                        copy.destination = PDFDestination(page: newPage, at: destination.point)
                    }
                } else if let action = child.action {
                    copy.action = action
                }
                parent.insertChild(copy, at: parent.numberOfChildren)
                cloneOutline(child, into: copy, from: src, to: dst)
                copy.isOpen = child.isOpen
            }
        }
    }
}

// MARK: - PNG

extension FileToolKit {
    /// PNG compression without ImageIO's encoder: the smallest exact layout for Balanced,
    /// a palette of up to 256 colours that keeps soft transparency for Strong.
    enum Squeeze {
        struct Pixels {
            var width: Int
            var height: Int
            /// 1 grey, 2 grey + alpha, 3 RGB, 4 RGBA. Straight (not premultiplied) alpha.
            var channels: Int
            var sixteen: Bool
            var data: [UInt8]
        }

        static let colourChunks: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI"]

        static func png(_ src: URL, _ s: CompressSettings, target: Int64?, ctx: JobContext) throws -> Data {
            let bytes = [UInt8](try Data(contentsOf: src))
            guard let chunks = PNG.chunks(bytes), let header = chunks.first, header.type == "IHDR", header.data.count >= 13 else {
                throw JobError.failed("Couldn't read this PNG.")
            }
            if chunks.contains(where: { $0.type == "acTL" }) { throw JobError.failed("Animated PNGs can't be compressed yet.") }
            guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw JobError.failed("Couldn't decode this PNG.")
            }
            try ctx.checkCancelled()
            ctx.progress(0.1)

            // Only what changes how the picture looks survives, plus its rotation.
            let sourceType = header.data[9]
            var extra = chunks.filter { PNG.displayChunks.contains($0.type) }
            if let exif = chunks.first(where: { $0.type == "eXIf" }), let o = EXIF.orientation(exif.data), o != 1 {
                extra.append(PNG.Chunk(type: "eXIf", data: EXIF.orientationOnly(o)))
            }
            let image = Compressor.scaled(decoded, s.resize)
            if image !== decoded && decoded.colorSpace?.model != .rgb {
                // Resizing drew a grey picture into sRGB, so the old colour notes no longer apply.
                extra.removeAll { colourChunks.contains($0.type) }
            }
            let grey = image.colorSpace?.model == .monochrome
            // Turning colour into grey is only safe when no RGB colour profile depends on it.
            let allowGrey = grey || sourceType == 0 || sourceType == 4 || !extra.contains { $0.type == "iCCP" }

            func lossless() throws -> [UInt8] {
                let px = try pixels(image, grey: grey)
                try ctx.checkCancelled()
                return PNG.encode(losslessRaster(px, allowGrey: allowGrey), extra: extra)
            }
            func palette(_ picture: CGImage, colors: Int) throws -> [UInt8] {
                let px = try pixels(picture, grey: false, forceEight: true)
                try ctx.checkCancelled()
                if colors >= 256, let exact = exactPalette(px, opaque: isOpaque(px)) {
                    return PNG.encode(exact, extra: extra)
                }
                let raster = Quantizer.raster(px, colors: colors, ctx: ctx)
                try ctx.checkCancelled()
                return PNG.encode(raster, extra: extra)
            }

            guard let target else {
                let out = s.preset == .balanced || grey ? try lossless() : try palette(image, colors: 256)
                ctx.progress(0.95)
                return Data(out)
            }
            let exact = try lossless()
            if exact.count <= target { return Data(exact) }
            guard !grey else { throw JobError.failed("Couldn't get this file that small.") }
            for (i, colors) in [256, 128, 64, 32].enumerated() {
                try ctx.checkCancelled()
                ctx.progress(0.3 + Double(i) * 0.12)
                let out = try palette(image, colors: colors)
                if out.count <= target { return Data(out) }
            }
            // Still too big: a smaller picture with a full palette.
            var shrunk = image
            for _ in 0..<8 {
                try ctx.checkCancelled()
                shrunk = ImageEngine.resized(shrunk, width: max(1, shrunk.width * 4 / 5), height: max(1, shrunk.height * 4 / 5))
                guard shrunk.width >= 16, shrunk.height >= 16 else { break }
                let out = try palette(shrunk, colors: 256)
                if out.count <= target { return Data(out) }
            }
            throw JobError.failed("Couldn't get this file that small.")
        }

        /// Straight samples in the picture's own colour space (sRGB when it has none that fits).
        static func pixels(_ image: CGImage, grey: Bool, forceEight: Bool = false) throws -> Pixels {
            do {
                return try readPixels(image, grey: grey, forceEight: forceEight)
            } catch where grey {
                // Some grey layouts don't convert directly; RGB always does, and neutral pixels
                // turn back into grey when the PNG is written.
                return try readPixels(image, grey: false, forceEight: forceEight)
            }
        }

        private static func readPixels(_ image: CGImage, grey: Bool, forceEight: Bool) throws -> Pixels {
            let alpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
            let sixteen = image.bitsPerComponent > 8 && !forceEight
            var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            if space.model == .indexed, let base = space.baseColorSpace { space = base }
            if !grey && space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
            if grey && space.model != .monochrome { space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! }
            let channels = (grey ? 1 : 3) + (alpha ? 1 : 0)
            var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
            if sixteen { info |= CGBitmapInfo.byteOrder16Big.rawValue }
            let depth = sixteen ? 16 : 8
            guard let format = vImage_CGImageFormat(bitsPerComponent: depth, bitsPerPixel: depth * channels, colorSpace: space,
                                                    bitmapInfo: CGBitmapInfo(rawValue: info)) else {
                throw JobError.failed("Couldn't read this PNG's pixels.")
            }
            let buffer = try vImage_Buffer(cgImage: image, format: format)
            defer { buffer.free() }
            let rowBytes = image.width * channels * (depth / 8)
            var data = [UInt8](repeating: 0, count: rowBytes * image.height)
            data.withUnsafeMutableBytes { dst in
                guard let d = dst.baseAddress else { return }
                for y in 0..<image.height {
                    (d + y * rowBytes).copyMemory(from: buffer.data + y * buffer.rowBytes, byteCount: rowBytes)
                }
            }
            return Pixels(width: image.width, height: image.height, channels: channels, sixteen: sixteen, data: data)
        }

        static func isOpaque(_ px: Pixels) -> Bool {
            guard px.channels == 2 || px.channels == 4 else { return true }
            let size = px.sixteen ? 2 : 1
            let stride = px.channels * size
            let alpha = (px.channels - 1) * size
            return px.data.withUnsafeBufferPointer { d in
                var i = alpha
                while i < d.count {
                    if d[i] != 0xFF || (size == 2 && d[i + 1] != 0xFF) { return false }
                    i += stride
                }
                return true
            }
        }

        /// The smallest exact layout: a palette when there are 256 colours or fewer, grey when
        /// every pixel is neutral, 8 bits when 16 aren't needed, no alpha when it's all opaque.
        static func losslessRaster(_ source: Pixels, allowGrey: Bool) -> PNG.Raster {
            var px = source
            if px.sixteen {
                let fitsEight: Bool = px.data.withUnsafeBufferPointer { d in
                    var i = 0
                    while i + 1 < d.count {
                        if d[i] != d[i + 1] { return false }
                        i += 2
                    }
                    return true
                }
                if fitsEight {
                    px.data = stride(from: 0, to: px.data.count, by: 2).map { px.data[$0] }
                    px.sixteen = false
                }
            }
            let size = px.sixteen ? 2 : 1
            let hasAlpha = px.channels == 2 || px.channels == 4
            let colorChannels = px.channels - (hasAlpha ? 1 : 0)
            let opaque = isOpaque(px)
            var neutral = colorChannels == 1
            if colorChannels == 3 && allowGrey {
                neutral = px.data.withUnsafeBufferPointer { d in
                    let stride = px.channels * size
                    var i = 0
                    while i < d.count {
                        for k in 0..<size where d[i + k] != d[i + size + k] || d[i + k] != d[i + 2 * size + k] {
                            return false
                        }
                        i += stride
                    }
                    return true
                }
            }
            if !px.sixteen && colorChannels == 3, let raster = exactPalette(px, opaque: opaque) {
                return raster
            }
            let keepAlpha = hasAlpha && !opaque
            let colorBytes = (neutral ? 1 : 3) * size
            let outStride = colorBytes + (keepAlpha ? size : 0)
            let inStride = px.channels * size
            let count = px.width * px.height
            var out = [UInt8](repeating: 0, count: count * outStride)
            px.data.withUnsafeBufferPointer { d in
                out.withUnsafeMutableBufferPointer { o in
                    for p in 0..<count {
                        let i = p * inStride
                        let j = p * outStride
                        for k in 0..<colorBytes { o[j + k] = d[i + k] }
                        if keepAlpha {
                            for k in 0..<size { o[j + colorBytes + k] = d[i + (px.channels - 1) * size + k] }
                        }
                    }
                }
            }
            let type: UInt8 = neutral ? (keepAlpha ? 4 : 0) : (keepAlpha ? 6 : 2)
            return PNG.Raster(width: px.width, height: px.height, colorType: type, bitDepth: px.sixteen ? 16 : 8, rows: out)
        }

        /// A lossless palette from 8-bit RGB(A), or nil when there are more than 256 colours.
        static func exactPalette(_ px: Pixels, opaque: Bool) -> PNG.Raster? {
            guard !px.sixteen, px.channels >= 3 else { return nil }
            var lookup: [UInt32: UInt8] = [:]
            lookup.reserveCapacity(512)
            var colors: [UInt32] = []
            let count = px.width * px.height
            var indices = [UInt8](repeating: 0, count: count)
            let fits: Bool = px.data.withUnsafeBufferPointer { d in
                var last = UInt32.max
                var lastIndex: UInt8 = 0
                for p in 0..<count {
                    let i = p * px.channels
                    let a = px.channels == 4 ? UInt32(d[i + 3]) : 255
                    // Every fully clear pixel is the same colour.
                    let key = a == 0 ? 0 : UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | a
                    if key != last {
                        if let known = lookup[key] {
                            lastIndex = known
                        } else {
                            guard colors.count < 256 else { return false }
                            lastIndex = UInt8(colors.count)
                            lookup[key] = lastIndex
                            colors.append(key)
                        }
                        last = key
                    }
                    indices[p] = lastIndex
                }
                return true
            }
            guard fits else { return nil }
            return Quantizer.indexed(width: px.width, height: px.height, palette: colors, indices: indices, opaque: opaque)
        }
    }

    // MARK: Quantizer

    /// Median cut over a weighted 5-5-5-4 histogram in premultiplied space, two k-means rounds,
    /// then Floyd-Steinberg dithering at 85%. Soft shadows keep their transparency.
    enum Quantizer {
        static func raster(_ px: Squeeze.Pixels, colors: Int, ctx: JobContext) -> PNG.Raster {
            let (palette, indices) = quantize(px, colors: colors, ctx: ctx)
            return indexed(width: px.width, height: px.height, palette: palette, indices: indices, opaque: px.channels == 3)
        }

        /// Packs indices into a PNG raster. See-through entries go first so tRNS stays short,
        /// and small palettes use fewer bits per pixel.
        static func indexed(width: Int, height: Int, palette: [UInt32], indices: [UInt8], opaque: Bool) -> PNG.Raster {
            let order = palette.indices.filter { palette[$0] & 0xFF < 255 } + palette.indices.filter { palette[$0] & 0xFF == 255 }
            var remap = [UInt8](repeating: 0, count: 256)
            var plte: [UInt8] = []
            var trns: [UInt8] = []
            for (newIndex, old) in order.enumerated() {
                remap[old] = UInt8(newIndex)
                let c = palette[old]
                let a = c & 0xFF
                plte += a == 0 ? [0, 0, 0] : [UInt8(c >> 24 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF)]
                if a < 255 { trns.append(UInt8(a)) }
            }
            let n = palette.count
            let depth: UInt8 = n <= 2 ? 1 : n <= 4 ? 2 : n <= 16 ? 4 : 8
            let perByte = 8 / Int(depth)
            let rowBytes = (width * Int(depth) + 7) / 8
            var rows = [UInt8](repeating: 0, count: rowBytes * height)
            indices.withUnsafeBufferPointer { idx in
                rows.withUnsafeMutableBufferPointer { out in
                    for y in 0..<height {
                        let row = y * rowBytes
                        let src = y * width
                        if depth == 8 {
                            for x in 0..<width { out[row + x] = remap[Int(idx[src + x])] }
                        } else {
                            for x in 0..<width {
                                let shift = 8 - Int(depth) * (x % perByte + 1)
                                out[row + x / perByte] |= remap[Int(idx[src + x])] << shift
                            }
                        }
                    }
                }
            }
            return PNG.Raster(width: width, height: height, colorType: 3, bitDepth: depth, rows: rows,
                              palette: plte, transparency: opaque ? [] : trns)
        }

        private struct Box {
            var range: Range<Int>
            var score: Double
            var channel: Int
        }

        private struct Sample {
            var color: SIMD4<Double>
            var weight: Double
        }

        /// Eyes care most about green and least about blue.
        private static let scale = SIMD4<Double>(0.9, 1.2, 0.7, 1.0)

        private static func key(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
            (r >> 3) << 14 | (g >> 3) << 9 | (b >> 3) << 4 | (a >> 4)
        }

        /// RGBA colours (r<<24 | g<<16 | b<<8 | a, straight alpha) and one index per pixel.
        static func quantize(_ px: Squeeze.Pixels, colors: Int, ctx: JobContext) -> ([UInt32], [UInt8]) {
            let count = px.width * px.height
            let ch = px.channels
            let buckets = 1 << 19
            var weight = [Double](repeating: 0, count: buckets)
            var sums = [SIMD4<Double>](repeating: .zero, count: buckets)
            var transparent = 0
            px.data.withUnsafeBufferPointer { d in
                for p in 0..<count {
                    let i = p * ch
                    let a = ch == 4 ? Int(d[i + 3]) : 255
                    if a == 0 {
                        transparent += 1
                        continue
                    }
                    // Premultiplied, so colour hidden by transparency doesn't take palette slots.
                    let r = Int(d[i]) * a / 255, g = Int(d[i + 1]) * a / 255, b = Int(d[i + 2]) * a / 255
                    let k = key(r, g, b, a)
                    weight[k] += 1
                    sums[k] += SIMD4(Double(r), Double(g), Double(b), Double(a))
                }
            }
            var samples: [Sample] = []
            samples.reserveCapacity(65_536)
            for k in 0..<buckets where weight[k] > 0 {
                samples.append(Sample(color: sums[k] / weight[k], weight: weight[k]))
            }
            let slots = max(2, colors - (transparent > 0 ? 1 : 0))
            var palette: [SIMD4<Double>]
            if samples.count <= slots {
                palette = samples.map { $0.color }
            } else {
                palette = medianCut(samples, slots: slots)
                refine(&palette, samples)
            }
            if palette.isEmpty { palette = [SIMD4(0, 0, 0, 255)] }

            // Map every pixel, spreading the error to its neighbours.
            let transparentIndex = UInt8(truncatingIfNeeded: palette.count)   // only used when a slot was kept free
            var cache = [Int16](repeating: -1, count: buckets)
            var indices = [UInt8](repeating: 0, count: count)
            let width = px.width
            var errCur = [SIMD4<Double>](repeating: .zero, count: width + 2)
            var errNext = [SIMD4<Double>](repeating: .zero, count: width + 2)
            let strength = 0.85
            let top = SIMD4<Double>(repeating: 255)
            px.data.withUnsafeBufferPointer { d in
                for y in 0..<px.height {
                    if y % 64 == 0 && ctx.isCancelled { return }
                    for x in 0..<width {
                        let p = y * width + x
                        let i = p * ch
                        let a = ch == 4 ? Double(d[i + 3]) : 255
                        if a == 0 {
                            indices[p] = transparentIndex
                            continue
                        }
                        let original = SIMD4(Double(d[i]) * a / 255, Double(d[i + 1]) * a / 255, Double(d[i + 2]) * a / 255, a)
                        var want = (original + errCur[x + 1]).clamped(lowerBound: .zero, upperBound: top)
                        want.w = max(1, want.w)
                        want.x = min(want.x, want.w)
                        want.y = min(want.y, want.w)
                        want.z = min(want.z, want.w)
                        let k = key(Int(want.x), Int(want.y), Int(want.z), Int(want.w))
                        var index = Int(cache[k])
                        if index < 0 {
                            index = nearest(want, palette)
                            cache[k] = Int16(index)
                        }
                        indices[p] = UInt8(index)
                        let err = (want - palette[index]) * strength
                        errCur[x + 2] += err * (7.0 / 16)
                        errNext[x] += err * (3.0 / 16)
                        errNext[x + 1] += err * (5.0 / 16)
                        errNext[x + 2] += err * (1.0 / 16)
                    }
                    swap(&errCur, &errNext)
                    for x in errNext.indices { errNext[x] = .zero }
                }
            }
            var out: [UInt32] = palette.map { c in
                let a = max(0, min(255, c.w.rounded()))
                guard a > 0 else { return 0 }
                let r = max(0, min(255, (c.x * 255 / a).rounded()))
                let g = max(0, min(255, (c.y * 255 / a).rounded()))
                let b = max(0, min(255, (c.z * 255 / a).rounded()))
                return UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
            }
            if transparent > 0 { out.append(0) }
            return (out, indices)
        }

        /// Splits the box with the most spread at its weighted median until there are `slots` boxes.
        private static func medianCut(_ samples: [Sample], slots: Int) -> [SIMD4<Double>] {
            var order = Array(samples.indices)
            func stats(_ r: Range<Int>) -> (score: Double, channel: Int) {
                guard r.count > 1 else { return (0, 0) }
                var total = 0.0
                var mean = SIMD4<Double>.zero
                for i in r {
                    let s = samples[order[i]]
                    total += s.weight
                    mean += s.color * s.weight
                }
                guard total > 0 else { return (0, 0) }
                mean /= total
                var variance = SIMD4<Double>.zero
                for i in r {
                    let s = samples[order[i]]
                    let d = (s.color - mean) * scale
                    variance += d * d * s.weight
                }
                var channel = 0
                for c in 1..<4 where variance[c] > variance[channel] { channel = c }
                return (variance.sum(), channel)
            }
            let first = stats(0..<order.count)
            var boxes = [Box(range: 0..<order.count, score: first.score, channel: first.channel)]
            while boxes.count < slots {
                guard let pick = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }), boxes[pick].score > 0 else { break }
                let box = boxes[pick]
                let c = box.channel
                order[box.range].sort { samples[$0].color[c] < samples[$1].color[c] }
                let half = box.range.reduce(0.0) { $0 + samples[order[$1]].weight } / 2
                var acc = 0.0
                var cut = box.range.lowerBound + 1
                for i in box.range {
                    acc += samples[order[i]].weight
                    if acc >= half {
                        cut = min(max(i + 1, box.range.lowerBound + 1), box.range.upperBound - 1)
                        break
                    }
                }
                let left = box.range.lowerBound..<cut
                let right = cut..<box.range.upperBound
                let ls = stats(left), rs = stats(right)
                boxes[pick] = Box(range: left, score: ls.score, channel: ls.channel)
                boxes.append(Box(range: right, score: rs.score, channel: rs.channel))
            }
            return boxes.compactMap { box in
                var total = 0.0
                var mean = SIMD4<Double>.zero
                for i in box.range {
                    total += samples[order[i]].weight
                    mean += samples[order[i]].color * samples[order[i]].weight
                }
                return total > 0 ? mean / total : nil
            }
        }

        /// Two k-means rounds over the heaviest samples pull colours toward what's really there.
        private static func refine(_ palette: inout [SIMD4<Double>], _ samples: [Sample]) {
            let heavy = samples.count > 40_000 ? Array(samples.sorted { $0.weight > $1.weight }.prefix(40_000)) : samples
            for _ in 0..<2 {
                var acc = [SIMD4<Double>](repeating: .zero, count: palette.count)
                var totals = [Double](repeating: 0, count: palette.count)
                for s in heavy {
                    let i = nearest(s.color, palette)
                    acc[i] += s.color * s.weight
                    totals[i] += s.weight
                }
                for i in palette.indices where totals[i] > 0 { palette[i] = acc[i] / totals[i] }
            }
        }

        private static func nearest(_ c: SIMD4<Double>, _ palette: [SIMD4<Double>]) -> Int {
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (i, p) in palette.enumerated() {
                let d = (c - p) * scale
                let distance = (d * d).sum()
                if distance < bestDistance {
                    bestDistance = distance
                    best = i
                }
            }
            return best
        }
    }
}
