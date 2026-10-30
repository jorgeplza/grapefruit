import AppKit
import AVFoundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Shared by the seven video tools (Trim, Split, Snapshots, Speed, Crop, Join, Redact): one player,
// one preview box, one filmstrip, one transport row, and the ffmpeg/AVFoundation work behind each
// tool. Sizes are measured from the original's windows (2x screenshots). Everything is nested in
// `VideoToolKit` so nothing collides with the other tools.
enum VideoToolKit {

    // MARK: - Look

    enum Look {
        static let orange = ToolStyle.orange
        /// Preview box: 12pt continuous corners, near-black so letterboxing reads as part of the frame.
        static let previewCorner: CGFloat = 12
        static let previewFill = Color(white: 0.11)
        /// Controls under the preview sit 6pt further in than the preview (18pt from the window edge).
        static let inset: CGFloat = 6
        static let stripCorner: CGFloat = 6
        /// Trim handles: 16pt orange tabs with a 2×20pt white grip.
        static let handleWidth: CGFloat = 16
        static let rangeBorder: CGFloat = 3
        static let dim = Color.black.opacity(0.5)
        static let caption = Font.system(size: 12)
        static let label = Font.system(size: 13)
        static let value = Font.system(size: 15)
        static let mono = Font.system(size: 11.5, design: .monospaced)
        static let clock = Font.system(size: 12).monospacedDigit()
        static let track = Color.primary.opacity(0.055)
        /// Placeholder cells while thumbnails load.
        static let placeholder = Color(white: 0.5).opacity(0.2)

        /// Quick, interruptible springs. Reduce Motion gets no movement at all.
        static func motion(_ reduce: Bool) -> Animation? {
            reduce ? nil : .spring(duration: 0.25, bounce: 0.12)
        }
    }

    /// Preview height: the original's size, shrunk when the window wouldn't fit the screen.
    /// `rest` is the window height without the preview.
    @MainActor
    static func previewHeight(_ design: CGFloat, rest: CGFloat, anchor: NSPoint) -> CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame.height, visible > 0 else { return design }
        return max(160, min(design, (visible - rest - 32).rounded(.down)))
    }

    // MARK: - Text

    /// "0:04.00", "12:03.50", "1:02:03.45".
    static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        let hundredths = Int((s * 100).rounded())
        let cs = hundredths % 100
        let total = hundredths / 100
        let sec = total % 60
        let minutes = total / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d.%02d", minutes / 60, minutes % 60, sec, cs)
        }
        return String(format: "%d:%02d.%02d", minutes, sec, cs)
    }

    /// 2 → "2", 0.5 → "0.5", 1.25 → "1.25".
    static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    // Frames start at `offset + k / fps`. The offset is where the picture starts: 0 for most MP4
    // and MOV files, often a few hundredths of a second for MKV.

    /// Index of the frame on screen at `time`.
    static func frameIndex(_ time: Double, fps: Double, offset: Double = 0) -> Int {
        Int(((time - offset) * max(1, fps) + 0.0005).rounded(.down))
    }

    /// Start of the frame on screen at `time`.
    static func frameStart(_ time: Double, fps: Double, offset: Double = 0) -> Double {
        max(0, offset + Double(frameIndex(time, fps: fps, offset: offset)) / max(1, fps))
    }

    /// Nearest frame boundary.
    static func nearestBoundary(_ time: Double, fps: Double, offset: Double = 0) -> Double {
        max(0, offset + ((time - offset) * max(1, fps)).rounded() / max(1, fps))
    }
}

// MARK: - Media info

extension VideoToolKit {
    /// What ffprobe says about a file, with what the re-encodes need to keep it looking the same.
    struct Probe: Sendable {
        var duration: Double = 0
        var videoIndex = 0
        /// When the first frame shows, from the start of the file.
        var videoStart = 0.0
        var codec: String?
        var profile: String?
        var level = 0
        var width = 0
        var height = 0
        var rotation = 0
        var sar: Double = 1
        var fps: Double = 30
        /// Rate as ffmpeg writes it ("30000/1001"), for the fps filter.
        var frameRate = "30"
        var pixFmt = "yuv420p"
        var bitDepth = 8
        var colorPrimaries: String?
        var colorTransfer: String?
        var colorSpace: String?
        var colorRange: String?
        var videoExtradata: String?
        var audioCodec: String?
        var audioRate = 48_000
        var audioChannels = 2
        var audioExtradata: String?

        var hasVideo: Bool { codec != nil }
        var hasAudio: Bool { audioCodec != nil }
        var isHDR: Bool { colorTransfer == "arib-std-b67" || colorTransfer == "smpte2084" }

        /// Picture size as shown: rotation applied, non-square pixels made square.
        var displaySize: CGSize {
            let w = Double(width) * (sar > 0 ? sar : 1)
            let h = Double(height)
            return abs(rotation) % 180 == 90 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
    }

    static func probe(_ url: URL, ctx: JobContext? = nil) throws -> Probe {
        let ffprobe = try Binaries.require(Binaries.ffprobe, "ffmpeg")
        let result = try Shell.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_data_hash", "md5",
                                             "-show_format", "-show_streams", url.path],
                                   ctx: ctx, timeout: 60)
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw JobError.failed("Couldn't read this video.")
        }
        var p = Probe()
        let format = json["format"] as? [String: Any]
        let formatDuration = Double(format?["duration"] as? String ?? "") ?? 0
        let formatStart = Double(format?["start_time"] as? String ?? "") ?? 0
        var streamDuration = 0.0
        for stream in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = stream["codec_type"] as? String
            let codec = stream["codec_name"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            if type == "video", p.codec == nil, (disposition?["attached_pic"] as? Int) != 1 {
                p.codec = codec
                p.videoIndex = stream["index"] as? Int ?? 0
                p.profile = stream["profile"] as? String
                p.level = stream["level"] as? Int ?? 0
                p.width = stream["width"] as? Int ?? 0
                p.height = stream["height"] as? Int ?? 0
                p.pixFmt = stream["pix_fmt"] as? String ?? "yuv420p"
                p.colorPrimaries = stream["color_primaries"] as? String
                p.colorTransfer = stream["color_transfer"] as? String
                p.colorSpace = stream["color_space"] as? String
                p.colorRange = stream["color_range"] as? String
                p.videoExtradata = stream["extradata_hash"] as? String
                if let sar = stream["sample_aspect_ratio"] as? String {
                    let parts = sar.split(separator: ":").compactMap { Double($0) }
                    if parts.count == 2, parts[0] > 0, parts[1] > 0 { p.sar = parts[0] / parts[1] }
                }
                for key in ["avg_frame_rate", "r_frame_rate"] {
                    guard let rate = stream[key] as? String else { continue }
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    guard parts.count == 2, parts[1] > 0 else { continue }
                    let fps = parts[0] / parts[1]
                    if fps >= 1, fps <= 1_000 {
                        p.fps = fps
                        p.frameRate = rate
                        break
                    }
                }
                if let bits = Int(stream["bits_per_raw_sample"] as? String ?? ""), bits > 0 {
                    p.bitDepth = bits
                } else if p.pixFmt.contains("10") {
                    p.bitDepth = 10
                } else if p.pixFmt.contains("12") {
                    p.bitDepth = 12
                }
                if let tags = stream["tags"] as? [String: Any], let r = Int(tags["rotate"] as? String ?? "") {
                    p.rotation = r
                }
                for side in (stream["side_data_list"] as? [[String: Any]]) ?? [] {
                    if let r = side["rotation"] as? Int { p.rotation = r }
                    if let r = side["rotation"] as? Double { p.rotation = Int(r.rounded()) }
                }
                streamDuration = Double(stream["duration"] as? String ?? "") ?? 0
                let start = Double(stream["start_time"] as? String ?? "") ?? formatStart
                p.videoStart = max(0, start - formatStart)
            } else if type == "audio", p.audioCodec == nil {
                p.audioCodec = codec
                p.audioRate = Int(stream["sample_rate"] as? String ?? "") ?? 48_000
                p.audioChannels = stream["channels"] as? Int ?? 2
                p.audioExtradata = stream["extradata_hash"] as? String
            }
        }
        p.duration = formatDuration > 0 ? formatDuration : streamDuration
        if p.videoStart >= p.duration { p.videoStart = 0 }
        return p
    }
}

// MARK: - Work (runs on the job queue, never on the main thread)

extension VideoToolKit {
    static let appleContainers: Set<String> = ["mp4", "mov", "m4v"]

    static func seconds(_ t: Double) -> String { String(format: "%.6f", max(0, t)) }
    static func number(_ x: Double) -> String { String(format: "%.6g", x) }
    static func cmTime(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 120_000) }

    static func exportType(for ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mp4": .mp4
        case "mov": .mov
        case "m4v": .m4v
        default: nil
        }
    }

    static func containerArgs(_ ext: String) -> [String] {
        appleContainers.contains(ext.lowercased()) ? ["-movflags", "+faststart"] : []
    }

    /// Video encoder for re-encodes. HDR and 10-bit sources stay 10-bit HEVC so their colors survive;
    /// everything else becomes high quality H.264.
    static func videoCodecArgs(_ p: Probe, ext: String, hardware: Bool) -> [String] {
        var a: [String]
        if p.isHDR || p.bitDepth > 8 {
            a = hardware
                ? ["-c:v", "hevc_videotoolbox", "-q:v", "70", "-profile:v", "main10", "-pix_fmt", "p010le"]
                : ["-c:v", "libx265", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p10le",
                   "-x265-params", "log-level=error"]
            if appleContainers.contains(ext.lowercased()) { a += ["-tag:v", "hvc1"] }
        } else {
            a = ["-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p"]
        }
        // Keep the color description so players show the same picture.
        if let v = p.colorPrimaries, v != "unknown" { a += ["-color_primaries", v] }
        if let v = p.colorTransfer, v != "unknown" { a += ["-color_trc", v] }
        if let v = p.colorSpace, v != "unknown" { a += ["-colorspace", v] }
        if let v = p.colorRange, v != "unknown" { a += ["-color_range", v] }
        return a
    }

    static func audioCodecArgs(_ ext: String) -> [String] {
        ext.lowercased() == "webm" ? ["-c:a", "libopus", "-b:a", "160k"] : ["-c:a", "aac_at", "-b:a", "192k"]
    }

    /// Runs a re-encode; when VideoToolbox refuses (older Macs), tries again in software.
    static func encode(out: URL, duration: Double, ctx: JobContext, progress: ClosedRange<Double> = 0...1,
                       _ build: (Bool) -> [String]) throws {
        let first = build(true)
        do {
            try MediaEngine.ffmpeg(first, duration: duration, ctx: ctx, progressRange: progress)
        } catch JobError.cancelled {
            throw JobError.cancelled
        } catch {
            let second = build(false)
            guard second != first else { throw error }
            try? FileManager.default.removeItem(at: out)
            try MediaEngine.ffmpeg(second, duration: duration, ctx: ctx, progressRange: progress)
        }
    }

    /// Thread-safe slot for a value produced on another thread.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? { lock.withLock { stored } }
        func set(_ newValue: Value) { lock.withLock { stored = newValue } }
    }

    // MARK: Trim and split

    /// Lossless cut with AVFoundation. The file keeps the frames back to the previous keyframe and an
    /// edit list starts playback exactly at `start`, so the cut is frame-exact in every player.
    static func passthrough(_ src: URL, start: Double, end: Double, to out: URL, ctx: JobContext,
                            progress: ClosedRange<Double>) throws {
        guard let type = exportType(for: out.pathExtension) else { throw JobError.failed("Can't copy into this format.") }
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw JobError.failed("Can't export this video.")
        }
        session.timeRange = end.isFinite
            ? CMTimeRange(start: cmTime(start), end: cmTime(end))
            : CMTimeRange(start: cmTime(start), duration: .positiveInfinity)
        session.shouldOptimizeForNetworkUse = true
        try wait(for: session, to: out, as: type, ctx: ctx, progress: progress)
    }

    private static func wait(for session: AVAssetExportSession, to out: URL, as type: AVFileType,
                             ctx: JobContext, progress: ClosedRange<Double>) throws {
        let finished = DispatchSemaphore(value: 0)
        let failure = Box<any Error>()
        let low = progress.lowerBound
        let span = progress.upperBound - progress.lowerBound
        let export = Task.detached(priority: .userInitiated) {
            do {
                try await session.export(to: out, as: type)
            } catch {
                failure.set(error)
            }
            finished.signal()
        }
        let watcher = Task.detached(priority: .utility) {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { ctx.progress(low + span * p.fractionCompleted) }
            }
        }
        while finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if ctx.isCancelled { export.cancel() }
        }
        watcher.cancel()
        try ctx.checkCancelled()
        if let error = failure.value { throw JobError.failed(JobCenter.describe(error)) }
        ctx.progress(progress.upperBound)
    }

    /// Keeps `start..<end` (`end` = .infinity keeps the rest). MP4 and MOV are cut losslessly;
    /// MKV, and anything AVFoundation refuses, is re-encoded for a frame-exact cut.
    static func trim(_ src: URL, start: Double, end: Double, to out: URL, probe known: Probe? = nil,
                     ctx: JobContext, progress: ClosedRange<Double> = 0...1) throws {
        let ext = out.pathExtension.lowercased()
        if exportType(for: ext) != nil {
            do {
                try passthrough(src, start: start, end: end, to: out, ctx: ctx, progress: progress)
                return
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        let p = try known ?? probe(src, ctx: ctx)
        // Seek a quarter frame early, then keep frames by their own timestamps. Exact even when the
        // frames don't sit on whole multiples of the frame length (MKV often starts at 0.021s), and
        // the sound is cut at the same instant (a copied track would start at the previous keyframe).
        let seek = max(0, start - 0.25 / max(1, p.fps))
        let lead = start - seek
        let length = end.isFinite ? max(0.001, end - start) : nil
        var input = ["-ss", seconds(seek)]
        // Stop reading a little after the cut instead of decoding the rest of the file.
        if let length { input += ["-t", seconds(length + 1)] }
        input += ["-i", src.path]
        let video = (length.map { "trim=end=\(number($0))," } ?? "") + "setpts=PTS-STARTPTS"
        let audio = "atrim=start=\(number(lead))" + (length.map { ":end=\(number(lead + $0))" } ?? "") + ",asetpts=PTS-STARTPTS"
        let outLength = length ?? max(0.01, p.duration - start)
        try encode(out: out, duration: max(0.01, outLength), ctx: ctx, progress: progress) { hardware in
            input + ["-map", "0:\(p.videoIndex)", "-map", "0:a?", "-sn", "-dn", "-vf", video]
                + videoCodecArgs(p, ext: ext, hardware: hardware)
                + (p.hasAudio ? ["-af", audio] + audioCodecArgs(ext) : [])
                + ["-map_metadata", "0"] + containerArgs(ext) + [out.path]
        }
    }

    /// Cuts at `points` and writes "name 1.ext", "name 2.ext"... into `folder`.
    static func split(_ src: URL, at points: [Double], duration: Double, into folder: URL, ctx: JobContext) throws {
        let (stem, ext) = Output.split(src.lastPathComponent)
        let cuts = points.filter { $0 > 0 && $0 < duration }.sorted()
        let edges = [0] + cuts + [duration]
        var known: Probe?
        if exportType(for: ext) == nil { known = try probe(src, ctx: ctx) }
        let total = max(duration, 0.001)
        for i in 0..<(edges.count - 1) {
            try ctx.checkCancelled()
            let name = ext.isEmpty ? "\(stem) \(i + 1)" : "\(stem) \(i + 1).\(ext)"
            let last = i == edges.count - 2
            let span = (edges[i] / total)...(edges[i + 1] / total)
            try trim(src, start: edges[i], end: last ? .infinity : edges[i + 1],
                     to: folder.appendingPathComponent(name), probe: known, ctx: ctx, progress: span)
        }
    }

    // MARK: Snapshots

    /// Full-resolution PNGs of the frames shown at `times` (each the exact start of a frame).
    static func snapshots(_ src: URL, times: [Double], to outs: [URL], fps: Double, viaFFmpeg: Bool,
                          ctx: JobContext) throws {
        if !viaFFmpeg {
            do {
                try snapshotsWithAVFoundation(src, times: times, to: outs, ctx: ctx)
                return
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                for out in outs { try? FileManager.default.removeItem(at: out) }
            }
        }
        let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
        let p = try probe(src, ctx: ctx)
        for (i, t) in times.enumerated() {
            try ctx.checkCancelled()
            // ffmpeg starts at the first frame at or after the seek point; half a frame back lands on this one.
            let at = max(0, t - 0.5 / max(1, fps))
            try Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-ss", seconds(at),
                                   "-i", src.path, "-map", "0:\(p.videoIndex)", "-frames:v", "1", "-update", "1",
                                   outs[i].path], ctx: ctx)
            ctx.progress(Double(i + 1) / Double(times.count))
        }
    }

    private static func snapshotsWithAVFoundation(_ src: URL, times: [Double], to outs: [URL], ctx: JobContext) throws {
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (i, t) in times.enumerated() {
            try ctx.checkCancelled()
            let image = try frame(generator, at: t)
            try writePNG(image, to: outs[i])
            ctx.progress(Double(i + 1) / Double(times.count))
        }
    }

    /// The frame on screen at `t`, waiting on the calling (background) thread.
    private static func frame(_ generator: AVAssetImageGenerator, at t: Double) throws -> CGImage {
        // A hair past the frame's start so rounding never lands on the previous frame.
        if let image = generate(generator, at: t + 0.0005) { return image }
        // Before the first frame: take the first one.
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        defer { generator.requestedTimeToleranceAfter = .zero }
        guard let image = generate(generator, at: t) else { throw JobError.failed("Couldn't read that frame.") }
        return image
    }

    private static func generate(_ generator: AVAssetImageGenerator, at t: Double) -> CGImage? {
        let done = DispatchSemaphore(value: 0)
        let result = Box<CGImage>()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime(max(0, t)))]) { _, image, _, _, _ in
            if let image { result.set(image) }
            done.signal()
        }
        done.wait()
        return result.value
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw JobError.failed("Couldn't save the PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw JobError.failed("Couldn't save the PNG.") }
    }

    // MARK: Speed

    static let speedStops: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    /// Slider position (0...5, one unit per labelled stop) to a speed, rounded to tidy values.
    static func speed(at position: Double) -> Double {
        let last = Double(speedStops.count - 1)
        let p = min(max(position, 0), last)
        let i = min(Int(p), speedStops.count - 2)
        let raw = speedStops[i] + (speedStops[i + 1] - speedStops[i]) * (p - Double(i))
        let step = raw >= 2 ? 0.1 : 0.05
        return ((raw / step).rounded() * step * 100).rounded() / 100
    }

    /// atempo only takes 0.5...2 per instance, so bigger changes are chained.
    static func atempo(_ factor: Double) -> String {
        var f = factor
        var parts: [String] = []
        while f > 2.0001 { parts.append("atempo=2"); f /= 2 }
        while f < 0.4999 { parts.append("atempo=0.5"); f /= 0.5 }
        parts.append("atempo=\(number(f))")
        return parts.joined(separator: ",")
    }

    /// Plays `factor` times faster (or slower). The sound keeps its pitch.
    static func changeSpeed(_ src: URL, factor: Double, to out: URL, ctx: JobContext) throws {
        let p = try probe(src, ctx: ctx)
        guard p.hasVideo else { throw JobError.failed("This file has no video.") }
        let ext = out.pathExtension.lowercased()
        var graph = "[0:\(p.videoIndex)]setpts=(PTS-STARTPTS)/\(number(factor))"
        // Faster drops frames back to the original rate; much slower repeats frames so playback stays smooth.
        if factor > 1 || p.fps * factor < 24 { graph += ",fps=\(p.frameRate)" }
        graph += "[v]"
        var maps = ["-map", "[v]"]
        if p.hasAudio {
            graph += ";[0:a:0]asetpts=PTS-STARTPTS,\(atempo(factor))[a]"
            maps += ["-map", "[a]"]
        }
        try encode(out: out, duration: max(0.01, p.duration / factor), ctx: ctx) { hardware in
            ["-i", src.path, "-filter_complex", graph] + maps
                + videoCodecArgs(p, ext: ext, hardware: hardware)
                + (p.hasAudio ? audioCodecArgs(ext) : [])
                + ["-map_metadata", "0"] + containerArgs(ext) + [out.path]
        }
    }

    // MARK: Crop

    /// Even-sized, even-placed pixel rect inside `size` (most encoders need even dimensions).
    static func evenRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        let fullW = Int(size.width.rounded()), fullH = Int(size.height.rounded())
        let w = min(max(2, Int(rect.width.rounded()) & ~1), fullW & ~1)
        let h = min(max(2, Int(rect.height.rounded()) & ~1), fullH & ~1)
        let x = min(max(0, Int(rect.minX.rounded()) & ~1), (fullW - w) & ~1)
        let y = min(max(0, Int(rect.minY.rounded()) & ~1), (fullH - h) & ~1)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `rect` is in pixels of the picture as shown (rotation applied). The sound is copied as is.
    static func crop(_ src: URL, to rect: CGRect, output out: URL, ctx: JobContext) throws {
        let p = try probe(src, ctx: ctx)
        guard p.hasVideo else { throw JobError.failed("This file has no video.") }
        let ext = out.pathExtension.lowercased()
        let r = evenRect(rect, in: p.displaySize)
        var filters: [String] = []
        // ffmpeg rotates the picture upright first; non-square pixels are squared so the rect lines up.
        if abs(p.sar - 1) > 0.01, abs(p.rotation) % 180 == 0 { filters.append("scale=trunc(iw*sar/2)*2:ih,setsar=1") }
        filters.append("crop=\(Int(r.width)):\(Int(r.height)):\(Int(r.minX)):\(Int(r.minY))")
        try encode(out: out, duration: p.duration, ctx: ctx) { hardware in
            ["-i", src.path, "-map", "0:\(p.videoIndex)", "-map", "0:a?", "-sn", "-dn",
             "-vf", filters.joined(separator: ",")]
                + videoCodecArgs(p, ext: ext, hardware: hardware)
                + ["-c:a", "copy", "-map_metadata", "0"] + containerArgs(ext) + [out.path]
        }
    }

    // MARK: Join

    /// One MP4 from several clips, in order. Matching clips are copied (no quality loss, seconds);
    /// anything else is re-encoded to the first clip's size, letterboxed.
    static func join(_ sources: [URL], to out: URL, ctx: JobContext) throws {
        var probes: [Probe] = []
        for (i, src) in sources.enumerated() {
            try ctx.checkCancelled()
            probes.append(try probe(src, ctx: ctx))
            ctx.progress(0.02 * Double(i + 1) / Double(sources.count))
        }
        guard probes.allSatisfy(\.hasVideo) else { throw JobError.failed("One of these files has no video.") }
        let total = probes.reduce(0) { $0 + $1.duration }
        if canJoinByCopy(probes) {
            do {
                try joinByCopy(sources, first: probes[0], to: out, duration: total, ctx: ctx)
                return
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        try joinByEncode(sources, probes: probes, to: out, duration: total, ctx: ctx)
    }

    /// Stream copy only works when every clip was encoded the same way (same codec setup, size,
    /// rate, rotation and sound), and only for codecs that belong in an MP4.
    static func canJoinByCopy(_ probes: [Probe]) -> Bool {
        guard let first = probes.first, ["h264", "hevc"].contains(first.codec ?? "") else { return false }
        if let audio = first.audioCodec, !["aac", "alac", "mp3", "ac3", "eac3"].contains(audio) { return false }
        return probes.allSatisfy { p in
            p.codec == first.codec && p.profile == first.profile && p.width == first.width
                && p.height == first.height && p.pixFmt == first.pixFmt && p.rotation == first.rotation
                && abs(p.sar - first.sar) < 0.001 && abs(p.fps - first.fps) < 0.01
                && p.videoExtradata == first.videoExtradata
                && p.audioCodec == first.audioCodec && p.audioRate == first.audioRate
                && p.audioChannels == first.audioChannels && p.audioExtradata == first.audioExtradata
        }
    }

    private static func joinByCopy(_ sources: [URL], first: Probe, to out: URL, duration: Double, ctx: JobContext) throws {
        let folder = try ctx.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = folder.appendingPathComponent("list.txt")
        let lines = sources.map { "file '" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        var args = ["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]
        if first.codec == "hevc" { args += ["-tag:v", "hvc1"] }
        args += ["-movflags", "+faststart", out.path]
        try MediaEngine.ffmpeg(args, duration: duration, ctx: ctx, progressRange: 0.02...1)
    }

    private static func joinByEncode(_ sources: [URL], probes: [Probe], to out: URL, duration: Double,
                                     ctx: JobContext) throws {
        let size = probes[0].displaySize
        let w = max(2, Int(size.width.rounded()) & ~1)
        let h = max(2, Int(size.height.rounded()) & ~1)
        let rate = probes[0].fps > 60.5 ? "60" : probes[0].frameRate
        let anyAudio = probes.contains(where: \.hasAudio)
        var inputs: [String] = []
        var graph: [String] = []
        var pads = ""
        for (i, (src, p)) in zip(sources, probes).enumerated() {
            inputs += ["-i", src.path]
            var chain = "[\(i):\(p.videoIndex)]"
            if p.isHDR {
                // HDR clips are tone mapped so they sit next to SDR ones.
                chain += "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,"
            }
            chain += "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=black,"
            chain += "setsar=1,fps=\(rate),format=yuv420p,setpts=PTS-STARTPTS[v\(i)]"
            graph.append(chain)
            pads += "[v\(i)]"
            if anyAudio {
                if p.hasAudio {
                    graph.append("[\(i):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(i)]")
                } else {
                    graph.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(number(max(0.05, p.duration)))[a\(i)]")
                }
                pads += "[a\(i)]"
            }
        }
        graph.append("\(pads)concat=n=\(sources.count):v=1:a=\(anyAudio ? 1 : 0)[v]" + (anyAudio ? "[a]" : ""))
        var args = inputs + ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
        if anyAudio { args += ["-map", "[a]"] }
        args += ["-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p"]
        if anyAudio { args += ["-c:a", "aac_at", "-b:a", "192k"] }
        args += ["-movflags", "+faststart", out.path]
        try MediaEngine.ffmpeg(args, duration: duration, ctx: ctx, progressRange: 0.02...1)
    }

    // MARK: Redact

    struct Redaction: Sendable, Equatable {
        /// 0...1 of the picture as shown.
        var rect: CGRect
        var start: Double
        var end: Double
    }

    enum RedactStyle: Sendable, Equatable {
        case solid(red: Double, green: Double, blue: Double)
        case blur
    }

    /// Covers each box during its time range, with a solid color or a heavy blur. Sound is copied.
    static func redact(_ src: URL, boxes: [Redaction], style: RedactStyle, to out: URL, ctx: JobContext) throws {
        let p = try probe(src, ctx: ctx)
        guard p.hasVideo else { throw JobError.failed("This file has no video.") }
        guard !boxes.isEmpty else { throw JobError.failed("Draw a box over the area to hide.") }
        let ext = out.pathExtension.lowercased()
        let size = p.displaySize
        // Ranges grow by half a frame on each side so the edges are always covered.
        let pad = 0.5 / max(1, p.fps)
        func when(_ box: Redaction) -> String {
            let a = box.start <= 0.001 ? -1 : box.start - pad
            let b = box.end >= p.duration - 0.01 ? p.duration + 3_600 : box.end + pad
            return "enable='between(t,\(number(a)),\(number(b)))'"
        }
        func pixels(_ box: Redaction) -> CGRect {
            evenRect(CGRect(x: box.rect.minX * size.width, y: box.rect.minY * size.height,
                            width: box.rect.width * size.width, height: box.rect.height * size.height), in: size)
        }
        var args = ["-i", src.path]
        let label: String
        switch style {
        case .solid(let red, let green, let blue):
            let hex = String(format: "0x%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
                             Int((blue * 255).rounded()))
            let draws = boxes.map { box -> String in
                let r = pixels(box)
                return "drawbox=x=\(Int(r.minX)):y=\(Int(r.minY)):w=\(Int(r.width)):h=\(Int(r.height)):color=\(hex)@1:t=fill:\(when(box))"
            }
            args += ["-filter_complex", "[0:\(p.videoIndex)]" + draws.joined(separator: ",") + "[v]"]
            label = "[v]"
        case .blur:
            var graph: [String] = []
            let copies = (0..<boxes.count).map { "[c\($0)]" }.joined()
            graph.append("[0:\(p.videoIndex)]split=\(boxes.count + 1)[base]\(copies)")
            var last = "base"
            for (i, box) in boxes.enumerated() {
                let r = pixels(box)
                let sigma = max(6, min(r.width, r.height) / 5)
                graph.append("[c\(i)]crop=\(Int(r.width)):\(Int(r.height)):\(Int(r.minX)):\(Int(r.minY)),gblur=sigma=\(number(sigma)):steps=2[b\(i)]")
                graph.append("[\(last)][b\(i)]overlay=\(Int(r.minX)):\(Int(r.minY)):\(when(box))[o\(i)]")
                last = "o\(i)"
            }
            args += ["-filter_complex", graph.joined(separator: ";")]
            label = "[\(last)]"
        }
        let base = args
        try encode(out: out, duration: p.duration, ctx: ctx) { hardware in
            base + ["-map", label, "-map", "0:a?", "-sn", "-dn"]
                + videoCodecArgs(p, ext: ext, hardware: hardware)
                + ["-c:a", "copy", "-map_metadata", "0"] + containerArgs(ext) + [out.path]
        }
    }

    // MARK: Preview copy

    /// A light MP4 that AVFoundation can play, for files it can't open (MKV, WebM...). Frames keep
    /// their original times so the preview lines up with the original.
    static func makePreviewCopy(_ src: URL, probe p: Probe, in folder: URL, ctx: JobContext) throws -> URL {
        let out = folder.appendingPathComponent("preview.mp4")
        var audio: [String] = []
        if p.hasAudio {
            audio = p.audioCodec == "aac"
                ? ["-map", "0:a:0", "-c:a", "copy"]
                : ["-map", "0:a:0", "-c:a", "aac_at", "-b:a", "128k", "-ac", "2"]
        }
        // Same pictures in a new box: seconds, when AVFoundation can decode the codec.
        if ["h264", "hevc"].contains(p.codec ?? "") {
            var a = ["-i", src.path, "-map", "0:\(p.videoIndex)", "-c:v", "copy"]
            if p.codec == "hevc" { a += ["-tag:v", "hvc1"] }
            a += audio + ["-sn", "-dn", out.path]
            do {
                try MediaEngine.ffmpeg(a, duration: p.duration, ctx: ctx)
                return out
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        let video = ["-i", src.path, "-map", "0:\(p.videoIndex)", "-vf", "scale='min(1280,iw)':-2",
                     "-fps_mode", "passthrough", "-g", "12", "-pix_fmt", "yuv420p"]
        do {
            try MediaEngine.ffmpeg(video + ["-c:v", "h264_videotoolbox", "-q:v", "60"] + audio + ["-sn", "-dn", out.path],
                                   duration: p.duration, ctx: ctx)
        } catch JobError.cancelled {
            throw JobError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: out)
            try MediaEngine.ffmpeg(video + ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"] + audio
                                   + ["-sn", "-dn", out.path], duration: p.duration, ctx: ctx)
        }
        return out
    }

    /// Whether AVFoundation can play the file's picture.
    static func canPlay(_ asset: AVURLAsset) async -> Bool {
        guard let loaded = try? await asset.load(.isPlayable, .tracks) else { return false }
        return loaded.0 && loaded.1.contains { $0.mediaType == .video }
    }

    /// The frame on screen at `time`, small, with that frame's exact start time.
    static func still(_ asset: AVAsset, at time: Double, maxSize: CGSize) async -> (image: CGImage, time: Double)? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let result = try? await generator.image(at: cmTime(max(0, time) + 0.0005)) {
            return (result.image, result.actualTime.seconds)
        }
        // Before the first frame (some files start their picture a moment in): take the first one.
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let result = try? await generator.image(at: cmTime(max(0, time))) else { return nil }
        return (result.image, result.actualTime.seconds)
    }

    /// A small frame for list rows: from AVFoundation, or from ffmpeg for formats it can't open.
    /// Blocks while ffmpeg runs, so call it off the main thread.
    static func poster(_ url: URL, at time: Double, maxPixels: CGFloat) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        if await canPlay(asset),
           let frame = await still(asset, at: time, maxSize: CGSize(width: maxPixels, height: maxPixels)) {
            return frame.image
        }
        guard let ffmpeg = Binaries.ffmpeg,
              let result = try? Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-ss", seconds(time),
                                                   "-i", url.path, "-map", "0:v:0", "-frames:v", "1",
                                                   "-vf", "scale=\(Int(maxPixels)):-2", "-f", "image2pipe", "-c:v", "png", "-"],
                                          timeout: 30),
              let source = CGImageSourceCreateWithData(result.stdout as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Player

extension VideoToolKit {
    /// One clip in a tool window: loads it (through a light preview copy when AVFoundation can't
    /// open the format), plays, loops a range, seeks smoothly while scrubbing and steps by frame.
    @MainActor
    @Observable
    final class Player {
        enum Phase: Equatable {
            case loading
            case preparing(Double)
            case ready
            case failed(String)
        }

        let url: URL
        @ObservationIgnored let player = AVPlayer()
        private(set) var phase = Phase.loading
        private(set) var time = 0.0
        private(set) var isPlaying = false
        private(set) var duration = 0.0
        /// ffprobe's view of the original: size as shown, frame rate, codecs.
        private(set) var info = Probe()
        /// What AVFoundation plays: the original, or the preview copy.
        @ObservationIgnored private(set) var asset: AVURLAsset?
        private(set) var usesPreviewCopy = false

        /// While playing, jump back to the start of this range at its end.
        var loop: ClosedRange<Double>? { didSet { if loop != oldValue { armLoop() } } }
        /// Preview speed. The sound keeps its pitch.
        var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }

        @ObservationIgnored private var timeObserver: Any?
        @ObservationIgnored private var loopObserver: Any?
        @ObservationIgnored private var endObserver: NSObjectProtocol?
        @ObservationIgnored private var statusObservation: NSKeyValueObservation?
        @ObservationIgnored private var loadTask: Task<Void, Never>?
        @ObservationIgnored private var copyContext: JobContext?
        @ObservationIgnored private var copyFolder: URL?
        @ObservationIgnored private var pendingSeek: (time: CMTime, exact: Bool)?
        @ObservationIgnored private var seeking = false
        @ObservationIgnored private var stopped = false

        init(url: URL) {
            self.url = url
            player.actionAtItemEnd = .pause
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        var isReady: Bool { phase == .ready }
        var failure: String? {
            if case .failed(let message) = phase { return message }
            return nil
        }
        var frameDuration: Double { 1 / max(1, info.fps) }

        /// Start of the frame on screen at `t`.
        func frameStart(_ t: Double) -> Double {
            VideoToolKit.frameStart(t, fps: info.fps, offset: info.videoStart)
        }

        /// The frame boundary nearest to `t`.
        func nearestBoundary(_ t: Double) -> Double {
            VideoToolKit.nearestBoundary(t, fps: info.fps, offset: info.videoStart)
        }
        /// Display size in pixels; a safe 16:9 until the file is read.
        var displaySize: CGSize {
            let s = info.displaySize
            return s.width > 0 && s.height > 0 ? s : CGSize(width: 16, height: 9)
        }

        func start() {
            guard loadTask == nil, !stopped else { return }
            loadTask = Task { [weak self] in await self?.load() }
        }

        private func load() async {
            let url = self.url
            let probed: Probe
            do {
                probed = try await Task.detached(priority: .userInitiated) { try VideoToolKit.probe(url) }.value
            } catch {
                fail("Can't read this video.")
                return
            }
            guard !stopped else { return }
            guard probed.hasVideo, probed.width > 0, probed.height > 0 else {
                fail("This file has no video.")
                return
            }
            info = probed
            var asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            if await !VideoToolKit.canPlay(asset) {
                guard !stopped else { return }
                phase = .preparing(0)
                do {
                    let copy = try await makePreviewCopy(probed)
                    asset = AVURLAsset(url: copy, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    usesPreviewCopy = true
                } catch {
                    if !stopped { fail("Can't preview this video.") }
                    return
                }
                guard await VideoToolKit.canPlay(asset) else {
                    fail("Can't preview this video.")
                    return
                }
            }
            guard !stopped else { return }
            self.asset = asset
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            duration = seconds.isFinite && seconds > 0 ? seconds : probed.duration
            guard duration > 0 else {
                fail("This video has no length.")
                return
            }
            guard !stopped else { return }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.statusChanged(status) }
                }
            }
            player.replaceCurrentItem(with: item)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.ticked(t) }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
            armLoop()
        }

        private func makePreviewCopy(_ probed: Probe) async throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Grapefruit-preview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            copyFolder = folder
            let ctx = JobContext(scratch: folder) { [weak self] value in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, case .preparing = self.phase else { return }
                        self.phase = .preparing(value)
                    }
                }
            }
            copyContext = ctx
            let src = url
            return try await Task.detached(priority: .userInitiated) {
                try VideoToolKit.makePreviewCopy(src, probe: probed, in: folder, ctx: ctx)
            }.value
        }

        private func statusChanged(_ status: AVPlayerItem.Status) {
            guard !stopped else { return }
            switch status {
            case .readyToPlay:
                if phase != .ready { phase = .ready }
            case .failed:
                fail("Can't play this video.")
            default:
                break
            }
        }

        private func fail(_ message: String) {
            phase = .failed(message)
            isPlaying = false
        }

        private func ticked(_ t: CMTime) {
            guard !seeking, pendingSeek == nil else { return }
            let s = t.seconds
            guard s.isFinite else { return }
            time = min(max(0, s), duration)
            // Safety net for the loop observer.
            if isPlaying, let loop, s >= loop.upperBound + 0.05 { wrap() }
        }

        private func armLoop() {
            if let loopObserver { player.removeTimeObserver(loopObserver) }
            loopObserver = nil
            guard let loop, player.currentItem != nil, loop.upperBound < duration - 0.001 else { return }
            let end = NSValue(time: VideoToolKit.cmTime(loop.upperBound))
            loopObserver = player.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.wrap() }
            }
        }

        private func wrap() {
            guard isPlaying, let loop else { return }
            seek(to: loop.lowerBound)
            player.rate = rate
        }

        private func reachedEnd() {
            guard isPlaying else { return }
            if let loop {
                seek(to: loop.lowerBound)
                player.rate = rate
            } else {
                isPlaying = false
            }
        }

        func togglePlay() {
            isPlaying ? pause() : play()
        }

        func play() {
            guard isReady else { return }
            let lower = loop?.lowerBound ?? 0
            let upper = loop?.upperBound ?? duration
            if time >= upper - frameDuration * 0.5 || time < lower - 0.001 { seek(to: lower) }
            isPlaying = true
            player.rate = rate
        }

        func pause() {
            guard isPlaying else { return }
            isPlaying = false
            player.pause()
            if !seeking, pendingSeek == nil {
                let now = player.currentTime().seconds
                if now.isFinite { time = min(max(0, now), duration) }
            }
        }

        /// Seeks, chasing the latest target while a previous seek is still running (smooth scrubbing).
        func seek(to seconds: Double, exact: Bool = true) {
            guard player.currentItem != nil, seconds.isFinite else { return }
            let t = min(max(0, seconds), duration)
            time = t
            pendingSeek = (VideoToolKit.cmTime(t), exact)
            if !seeking { runSeek() }
        }

        private func runSeek() {
            guard let next = pendingSeek, !stopped else {
                seeking = false
                return
            }
            pendingSeek = nil
            seeking = true
            let tolerance = next.exact ? CMTime.zero : CMTime(value: 1, timescale: 20)
            player.seek(to: next.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.runSeek() }
                }
            }
        }

        /// One frame back or forward, kept inside `range` when given.
        func step(_ frames: Int, within range: ClosedRange<Double>? = nil) {
            guard isReady else { return }
            pause()
            let target = time + Double(frames) * frameDuration
            if let range {
                let lastFrame = max(range.lowerBound, range.upperBound - frameDuration * 0.5)
                if target < range.lowerBound - 0.0005 {
                    seek(to: range.lowerBound)
                    return
                }
                if target > lastFrame + 0.0005 {
                    seek(to: frameStart(lastFrame))
                    return
                }
            }
            if let item = player.currentItem, !seeking, pendingSeek == nil,
               frames > 0 ? item.canStepForward : item.canStepBackward {
                item.step(byCount: frames)
            } else {
                seek(to: target)
            }
        }

        /// Stops playback and lets go of the file. Called when the window closes.
        func stop() {
            guard !stopped else { return }
            stopped = true
            loadTask?.cancel()
            copyContext?.cancel()
            isPlaying = false
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let loopObserver { player.removeTimeObserver(loopObserver) }
            timeObserver = nil
            loopObserver = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            statusObservation?.invalidate()
            statusObservation = nil
            player.replaceCurrentItem(with: nil)
            if let folder = copyFolder {
                DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }
}

// MARK: - Thumbnails

extension VideoToolKit {
    /// Filmstrip frames, generated off the main thread and published as they arrive.
    @MainActor
    @Observable
    final class Thumbnails {
        private(set) var images: [Int: CGImage] = [:]
        /// Every frame was tried (a few may have failed and stay grey).
        private(set) var finished = false
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var signature = ""

        /// `count` cells of `cell` points across the whole clip, cropped to fill.
        func load(_ asset: AVAsset?, duration: Double, count: Int, cell: CGSize, aspect: CGFloat) {
            guard let asset, duration > 0, count > 0, cell.width > 0, cell.height > 0 else { return }
            let key = "\(count)-\(Int(cell.width))x\(Int(cell.height))"
            guard key != signature else { return }
            signature = key
            task?.cancel()
            images = [:]
            finished = false
            var size = cell
            if aspect > cell.width / cell.height {
                size.width = cell.height * aspect
            } else {
                size.height = cell.width / max(aspect, 0.01)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: ceil(size.width * 2), height: ceil(size.height * 2))
            let slot = duration / Double(count)
            let tolerance = CMTime(seconds: slot / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * slot, preferredTimescale: 600) }
            task = Task { [weak self] in
                for await result in generator.images(for: times) {
                    if Task.isCancelled { return }
                    guard case .success(let requested, let image, _) = result else { continue }
                    let index = min(count - 1, max(0, Int((requested.seconds / slot).rounded(.down))))
                    self?.images[index] = image
                }
                if !Task.isCancelled { self?.finished = true }
            }
        }

        func cancel() {
            task?.cancel()
        }
    }
}

// MARK: - Views

extension VideoToolKit {
    /// AVPlayerLayer with no controls.
    struct PlayerSurface: NSViewRepresentable {
        let player: AVPlayer
        var cornerRadius: CGFloat = 0

        func makeNSView(context: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer.player = player
            view.playerLayer.videoGravity = .resizeAspect
            view.round(cornerRadius)
            return view
        }

        func updateNSView(_ view: PlayerLayerView, context: Context) {
            if view.playerLayer.player !== player { view.playerLayer.player = player }
            view.round(cornerRadius)
        }

        static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
            view.playerLayer.player = nil
        }
    }

    final class PlayerLayerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
        }

        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func round(_ radius: CGFloat) {
            layer?.cornerRadius = radius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = radius > 0
        }

        // Clicks belong to the SwiftUI overlays.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The video's rect inside `bounds`, letterboxed.
    static func fitted(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: size, insideRect: bounds)
    }

    /// Rounded dark box with the video, a spinner while it loads and a short message if it can't.
    /// `overlay` gets the video's rect in the box.
    struct PreviewBox<Overlay: View>: View {
        let player: Player
        var height: CGFloat
        @ViewBuilder var overlay: (CGRect) -> Overlay

        var body: some View {
            GeometryReader { geo in
                let video = VideoToolKit.fitted(player.displaySize, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Look.previewCorner, style: .continuous)
                        .fill(Look.previewFill)
                    PlayerSurface(player: player.player, cornerRadius: Look.previewCorner)
                        .opacity(player.isReady ? 1 : 0)
                        .animation(.easeOut(duration: 0.18), value: player.isReady)
                    PreviewStatus(player: player, onDark: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                    if player.isReady { overlay(video) }
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Look.previewCorner, style: .continuous))
        }
    }

    /// Spinner, preview-copy progress, or a short error.
    struct PreviewStatus: View {
        let player: Player
        var onDark: Bool

        var body: some View {
            let tint = onDark ? Color.white.opacity(0.72) : ToolStyle.secondary
            Group {
                switch player.phase {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case .preparing(let value):
                    VStack(spacing: 8) {
                        ProgressView(value: value)
                            .progressViewStyle(.linear)
                            .tint(Look.orange)
                            .frame(width: 140)
                        Text("Preparing preview")
                            .font(Look.caption)
                            .foregroundStyle(tint)
                    }
                case .failed(let message):
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 18))
                        Text(message)
                            .font(Look.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 24)
                case .ready:
                    EmptyView()
                }
            }
            .environment(\.colorScheme, onDark ? .dark : .light)
            .allowsHitTesting(false)
        }
    }

    /// Thumbnails across the whole clip, cropped to fill narrow cells, grey shimmer while loading.
    struct Filmstrip: View {
        let player: Player
        let thumbs: Thumbnails

        static func cells(for size: CGSize) -> Int {
            max(1, Int((size.width / max(18, size.height * 0.5625)).rounded()))
        }

        var body: some View {
            GeometryReader { geo in
                let count = Filmstrip.cells(for: geo.size)
                let cell = CGSize(width: geo.size.width / CGFloat(count), height: geo.size.height)
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        ZStack {
                            Look.placeholder
                            if let image = thumbs.images[i] {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: cell.width, height: cell.height)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: cell.width, height: cell.height)
                        .clipped()
                    }
                }
                .animation(.easeOut(duration: 0.2), value: thumbs.images.count)
                .overlay {
                    if player.failure == nil, !thumbs.finished, thumbs.images.count < count { Shimmer() }
                }
                .task(id: "\(count)|\(Int(cell.width))|\(Int(cell.height))|\(player.isReady)") {
                    guard player.isReady else { return }
                    let size = player.displaySize
                    thumbs.load(player.asset, duration: player.duration, count: count, cell: cell,
                                aspect: size.width / size.height)
                }
            }
        }
    }

    /// A soft light sweep over loading placeholders. Still when Reduce Motion is on.
    struct Shimmer: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var travel = false

        var body: some View {
            GeometryReader { geo in
                if !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: travel ? geo.size.width : -geo.size.width * 0.45)
                        .onAppear {
                            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) { travel = true }
                        }
                }
            }
            .clipped()
            .allowsHitTesting(false)
        }
    }

    /// The white playhead: 2pt with a soft shadow so it reads on any frame.
    struct PlayheadLine: View {
        var height: CGFloat

        var body: some View {
            RoundedRectangle(cornerRadius: 1)
                .fill(.white)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
                .allowsHitTesting(false)
        }
    }

    /// The rounded triangle that tops the playhead in Split.
    struct PlayheadKnob: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let r: CGFloat = 1.6
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r * 0.4, y: rect.minY + r * 1.6),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + r * 0.6, y: rect.maxY - r * 0.4))
            path.addQuadCurve(to: CGPoint(x: rect.midX - r * 0.6, y: rect.maxY - r * 0.4),
                              control: CGPoint(x: rect.midX, y: rect.maxY + r * 0.2))
            path.addLine(to: CGPoint(x: rect.minX + r * 0.4, y: rect.minY + r * 1.6))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }

    /// Frame back, play/pause, frame forward on the left; "0:01.60 / 0:04.00" on the right.
    /// With `speed`, the clock shows the sped-up result's timeline.
    struct Transport: View {
        let player: Player
        var showsPlay = true
        var showsSteps = true
        var range: ClosedRange<Double>? = nil
        var shortcuts = true
        var speed: Double = 1

        var body: some View {
            HStack(spacing: 7) {
                if showsSteps {
                    TransportButton(symbol: "backward.frame", help: "Previous frame") {
                        player.step(-1, within: range)
                    }
                    .modifier(Shortcut(key: .leftArrow, enabled: shortcuts))
                }
                if showsPlay {
                    TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                                    help: player.isPlaying ? "Pause" : "Play") {
                        player.togglePlay()
                    }
                    .modifier(Shortcut(key: .space, enabled: shortcuts))
                }
                if showsSteps {
                    TransportButton(symbol: "forward.frame", help: "Next frame") {
                        player.step(1, within: range)
                    }
                    .modifier(Shortcut(key: .rightArrow, enabled: shortcuts))
                }
                Spacer(minLength: 8)
                Text("\(VideoToolKit.clock(player.time / speed)) / \(VideoToolKit.clock(player.duration / speed))")
                    .font(Look.clock)
                    .foregroundStyle(ToolStyle.secondary)
                    .lineLimit(1)
            }
            .frame(height: 24)
            .disabled(!player.isReady)
        }
    }

    struct Shortcut: ViewModifier {
        var key: KeyEquivalent
        var enabled: Bool

        func body(content: Content) -> some View {
            if enabled {
                content.keyboardShortcut(key, modifiers: [])
            } else {
                content
            }
        }
    }

    /// A plain SF Symbol button with a soft hover disc.
    struct TransportButton: View {
        var symbol: String
        var help: String
        var action: () -> Void
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(hovering && isEnabled ? 0.07 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.78) : Color.secondary.opacity(0.5))
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel(help)
        }
    }

    /// The tool's window. Tool windows move when their background is dragged, so while the pointer
    /// is over a handle, box or row, that drag goes to the control instead of the window.
    @MainActor
    final class WindowLink {
        private weak var window: NSWindow?
        private var movable = true

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            movable = window.isMovableByWindowBackground
        }

        func pointerOverDragArea(_ inside: Bool) {
            window?.isMovableByWindowBackground = inside ? false : movable
        }
    }

    /// Marks a view whose drags belong to it, not to the window.
    struct OwnsDrags: ViewModifier {
        let link: WindowLink

        func body(content: Content) -> some View {
            content.onHover { link.pointerOverDragArea($0) }
        }
    }

    /// Links the window and stops the player when it closes (closing a window doesn't
    /// always tell SwiftUI its views went away).
    struct WindowHook: NSViewRepresentable {
        let link: WindowLink
        var onClose: () -> Void

        func makeNSView(context: Context) -> HookView {
            let view = HookView()
            view.link = link
            view.onClose = onClose
            return view
        }

        func updateNSView(_ view: HookView, context: Context) {
            view.onClose = onClose
        }

        final class HookView: NSView {
            var link: WindowLink?
            var onClose: () -> Void = {}
            private var token: NSObjectProtocol?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                forget()
                guard let window else { return }
                link?.attach(window)
                token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.onClose()
                        self?.forget()
                    }
                }
            }

            private func forget() {
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }

    /// The light tap Grapefruit uses for detents, when haptics are on.
    @MainActor
    static func haptic() {
        guard Settings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Dims everything in `outer` except `hole`. Animates with the hole.
    struct DimOutside: Shape {
        var outer: CGRect
        var hole: CGRect

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
            get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
            set {
                hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                              width: newValue.second.first, height: newValue.second.second)
            }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addRect(outer)
            path.addRect(hole)
            return path
        }
    }
}

// MARK: - Trim strip

extension VideoToolKit {
    /// Filmstrip with orange handles at both ends; the kept range is outlined, the rest dimmed.
    struct TrimStrip: View {
        let player: Player
        let thumbs: Thumbnails
        @Binding var start: Double
        @Binding var end: Double
        var minLength: Double
        @State private var grabbed: Double?

        private let handle = Look.handleWidth
        private let border = Look.rangeBorder

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let track = max(1, width - handle * 2)
                let length = max(player.duration, 0.001)
                let startX = handle + CGFloat(min(max(start, 0), length) / length) * track
                // Until the clip's length is known the handles sit at both ends.
                let shownEnd = end > 0 ? end : length
                let endX = handle + CGFloat(min(max(shownEnd, 0), length) / length) * track
                ZStack(alignment: .topLeading) {
                    // Frames under the whole strip; what gets cut is dimmed.
                    ZStack(alignment: .topLeading) {
                        Filmstrip(player: player, thumbs: thumbs)
                        Look.dim
                            .frame(width: max(0, startX - handle))
                        Look.dim
                            .frame(width: max(0, width - endX - handle))
                            .offset(x: endX + handle)
                    }
                    .frame(width: width, height: height - border * 2)
                    .clipShape(RoundedRectangle(cornerRadius: Look.stripCorner, style: .continuous))
                    .offset(y: border)

                    // The kept range: orange along the top and bottom.
                    Look.orange
                        .frame(width: max(0, endX - startX), height: border)
                        .offset(x: startX)
                    Look.orange
                        .frame(width: max(0, endX - startX), height: border)
                        .offset(x: startX, y: height - border)

                    PlayheadLine(height: height)
                        .offset(x: handle + CGFloat(min(max(player.time, 0), length) / length) * track - 1)
                        .opacity(player.isReady ? 1 : 0)

                    handleView(leading: true, height: height)
                        .offset(x: startX - handle)
                        .gesture(handleDrag(leading: true, track: track, length: length))
                    handleView(leading: false, height: height)
                        .offset(x: endX)
                        .gesture(handleDrag(leading: false, track: track, length: length))
                }
                .contentShape(Rectangle())
                .gesture(scrub(track: track, length: length))
            }
        }

        private func handleView(leading: Bool, height: CGFloat) -> some View {
            let r = Look.stripCorner
            let shape = UnevenRoundedRectangle(topLeadingRadius: leading ? r : 0, bottomLeadingRadius: leading ? r : 0,
                                               bottomTrailingRadius: leading ? 0 : r, topTrailingRadius: leading ? 0 : r,
                                               style: .continuous)
            return shape
                .fill(Look.orange)
                .overlay {
                    Capsule().fill(.white).frame(width: 2, height: 20)
                }
                .frame(width: handle, height: height)
                .contentShape(Rectangle().inset(by: -5))
                .pointerStyle(.columnResize)
                .accessibilityElement()
                .accessibilityLabel(leading ? "Start" : "End")
                .accessibilityValue(VideoToolKit.clock(leading ? start : end))
                .accessibilityAdjustableAction { direction in
                    let delta = (direction == .increment ? 1 : -1) * player.frameDuration
                    if leading {
                        start = min(max(0, start + delta), end - minLength)
                    } else {
                        end = max(min(player.duration, end + delta), start + minLength)
                    }
                }
        }

        private func handleDrag(leading: Bool, track: CGFloat, length: Double) -> some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if grabbed == nil {
                        grabbed = leading ? start : end
                        player.pause()
                    }
                    let origin = grabbed ?? 0
                    let t = origin + Double(value.translation.width / track) * length
                    if leading {
                        start = min(max(0, t), end - minLength)
                        player.seek(to: start)
                    } else {
                        end = max(min(length, t), start + minLength)
                        player.seek(to: max(start, end - player.frameDuration * 0.5))
                    }
                }
                .onEnded { _ in
                    grabbed = nil
                    if leading {
                        start = min(max(0, player.nearestBoundary(start)), end - minLength)
                        player.seek(to: start)
                    } else {
                        var t = player.nearestBoundary(end)
                        if t >= player.duration - player.frameDuration * 0.5 { t = player.duration }
                        end = max(min(player.duration, t), start + minLength)
                        player.seek(to: max(start, end - player.frameDuration * 0.5))
                    }
                }
        }

        private func scrub(track: CGFloat, length: Double) -> some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    player.pause()
                    let t = Double((value.location.x - handle) / track) * length
                    let last = max(start, end - player.frameDuration * 0.5)
                    player.seek(to: min(max(start, t), last))
                }
        }
    }
}

// MARK: - Split strip

extension VideoToolKit {
    struct SplitPoint: Identifiable, Equatable {
        let id = UUID()
        var time: Double
    }

    /// Filmstrip with the playhead (white, with a knob above) and orange split markers. A marker's
    /// knob below the strip removes it; its line drags it along.
    struct SplitStrip: View {
        let player: Player
        let thumbs: Thumbnails
        @Binding var points: [SplitPoint]
        var minGap: Double
        @State private var hovered: UUID?
        @State private var grabbed: (id: UUID, time: Double)?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        static let topLane: CGFloat = 10
        static let bottomLane: CGFloat = 14

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                let stripHeight = geo.size.height - Self.topLane - Self.bottomLane
                let length = max(player.duration, 0.001)
                let x = { (t: Double) in CGFloat(min(max(t, 0), length) / length) * width }
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Filmstrip(player: player, thumbs: thumbs)
                        segmentNumbers(width: width, height: stripHeight, x: x)
                    }
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Look.stripCorner, style: .continuous))
                    .offset(y: Self.topLane)
                    .contentShape(Rectangle())
                    .gesture(scrub(width: width, length: length))

                    ForEach(points) { point in
                        marker(point, stripHeight: stripHeight, width: width, length: length)
                            .offset(x: x(point.time) - 7)
                    }

                    if player.isReady {
                        let px = x(player.time)
                        PlayheadKnob()
                            .fill(.white)
                            .frame(width: 10, height: 9)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                            .offset(x: px - 5, y: 0)
                            .allowsHitTesting(false)
                        PlayheadLine(height: stripHeight + 2)
                            .offset(x: px - 1, y: Self.topLane - 1)
                    }
                }
            }
        }

        @ViewBuilder
        private func segmentNumbers(width: CGFloat, height: CGFloat, x: @escaping (Double) -> CGFloat) -> some View {
            if !points.isEmpty {
                let edges = [0] + points.map(\.time) + [player.duration]
                ForEach(0..<(edges.count - 1), id: \.self) { i in
                    let room = x(edges[i + 1]) - x(edges[i])
                    if room >= 22 {
                        Text("\(i + 1)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.55)))
                            .offset(x: x(edges[i]) + 4, y: height - 18)
                            .allowsHitTesting(false)
                    }
                }
            }
        }

        private func marker(_ point: SplitPoint, stripHeight: CGFloat, width: CGFloat, length: Double) -> some View {
            let isHovered = hovered == point.id
            return ZStack(alignment: .top) {
                // The line: drag to move.
                Rectangle()
                    .fill(Look.orange)
                    .frame(width: 2, height: stripHeight + 4)
                    .frame(width: 14, height: stripHeight + 4)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .offset(y: Self.topLane - 2)
                    .gesture(markerDrag(point, width: width, length: length))
                // The knob: click to remove, drag to move.
                ZStack {
                    Circle().fill(Look.orange)
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .opacity(isHovered ? 1 : 0)
                }
                .frame(width: isHovered ? 14 : 12, height: isHovered ? 14 : 12)
                .frame(width: 14, height: 14)
                .contentShape(Circle())
                .offset(y: Self.topLane + stripHeight)
                .gesture(markerDrag(point, width: width, length: length, removesOnClick: true))
                .help("Click to remove this split, drag to move it")
                .accessibilityElement()
                .accessibilityLabel("Split at \(VideoToolKit.clock(point.time))")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Remove") { remove(point) }
            }
            .frame(width: 14)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? point.id : (hovered == point.id ? nil : hovered) }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
        }

        private func remove(_ point: SplitPoint) {
            withAnimation(Look.motion(reduceMotion)) {
                points.removeAll { $0.id == point.id }
            }
        }

        private func markerDrag(_ point: SplitPoint, width: CGFloat, length: Double,
                                removesOnClick: Bool = false) -> some Gesture {
            DragGesture(minimumDistance: removesOnClick ? 0 : 1, coordinateSpace: .global)
                .onChanged { value in
                    if removesOnClick, grabbed == nil, abs(value.translation.width) < 2 { return }
                    if grabbed?.id != point.id { grabbed = (point.id, point.time) }
                    guard let origin = grabbed?.time,
                          let index = points.firstIndex(where: { $0.id == point.id }) else { return }
                    let lower = (index > 0 ? points[index - 1].time : 0) + minGap
                    let upper = (index < points.count - 1 ? points[index + 1].time : length) - minGap
                    guard lower <= upper else { return }
                    let t = origin + Double(value.translation.width / width) * length
                    points[index].time = min(max(lower, t), upper)
                    player.pause()
                    player.seek(to: points[index].time)
                }
                .onEnded { value in
                    guard grabbed != nil else {
                        // A click (not a drag that wandered off) removes the split.
                        let moved = hypot(value.translation.width, value.translation.height)
                        if removesOnClick, moved < 4 { remove(point) }
                        return
                    }
                    grabbed = nil
                    guard let index = points.firstIndex(where: { $0.id == point.id }) else { return }
                    // Settle on a frame boundary when that keeps the clips around it long enough.
                    let snapped = player.nearestBoundary(points[index].time)
                    let lower = (index > 0 ? points[index - 1].time : 0) + minGap - 0.0005
                    let upper = (index < points.count - 1 ? points[index + 1].time : length) - minGap + 0.0005
                    if snapped >= lower, snapped <= upper { points[index].time = snapped }
                    player.seek(to: points[index].time)
                }
        }

        private func scrub(width: CGFloat, length: Double) -> some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    player.pause()
                    player.seek(to: Double(value.location.x / width) * length)
                }
        }
    }
}

// MARK: - Box editing (Crop and Redact)

extension VideoToolKit {
    enum Grip: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesMinY: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
        var isHorizontalEdge: Bool { self == .top || self == .bottom }

        func point(in r: CGRect) -> CGPoint {
            let x = movesMinX ? r.minX : (movesMaxX ? r.maxX : r.midX)
            let y = movesMinY ? r.minY : (movesMaxY ? r.maxY : r.midY)
            return CGPoint(x: x, y: y)
        }

        var pointer: PointerStyle {
            switch self {
            case .topLeft: .frameResize(position: .topLeading)
            case .top: .frameResize(position: .top)
            case .topRight: .frameResize(position: .topTrailing)
            case .right: .frameResize(position: .trailing)
            case .bottomRight: .frameResize(position: .bottomTrailing)
            case .bottom: .frameResize(position: .bottom)
            case .bottomLeft: .frameResize(position: .bottomLeading)
            case .left: .frameResize(position: .leading)
            }
        }
    }

    static func move(_ r: CGRect, by t: CGSize, within b: CGRect) -> CGRect {
        var o = r.offsetBy(dx: t.width, dy: t.height)
        o.origin.x = min(max(o.minX, b.minX), b.maxX - o.width)
        o.origin.y = min(max(o.minY, b.minY), b.maxY - o.height)
        return o
    }

    /// Drags one grip of `r`, inside `b`, optionally keeping `aspect` (width / height).
    static func resize(_ r: CGRect, grip: Grip, by t: CGSize, within b: CGRect, aspect: CGFloat?, minSize: CGSize) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if grip.movesMinX { minX = min(max(b.minX, r.minX + t.width), r.maxX - minSize.width) }
        if grip.movesMaxX { maxX = max(min(b.maxX, r.maxX + t.width), r.minX + minSize.width) }
        if grip.movesMinY { minY = min(max(b.minY, r.minY + t.height), r.maxY - minSize.height) }
        if grip.movesMaxY { maxY = max(min(b.maxY, r.maxY + t.height), r.minY + minSize.height) }
        let free = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let a = aspect, a > 0 else { return free }

        var w = free.width, h = free.height
        let minW = max(minSize.width, minSize.height * a)
        if grip.isCorner {
            // Follow whichever side moved further; the opposite corner stays put.
            if abs(w - r.width) / max(r.width, 1) >= abs(h - r.height) / max(r.height, 1) { h = w / a } else { w = h * a }
            let anchorX = grip.movesMinX ? r.maxX : r.minX
            let anchorY = grip.movesMinY ? r.maxY : r.minY
            let roomX = grip.movesMinX ? anchorX - b.minX : b.maxX - anchorX
            let roomY = grip.movesMinY ? anchorY - b.minY : b.maxY - anchorY
            w = min(max(w, minW), roomX, roomY * a)
            h = w / a
            return CGRect(x: grip.movesMinX ? anchorX - w : anchorX, y: grip.movesMinY ? anchorY - h : anchorY,
                          width: w, height: h)
        }
        // An edge sets one side; the other grows around the center.
        if grip.isHorizontalEdge {
            let room = grip.movesMinY ? r.maxY - b.minY : b.maxY - r.minY
            h = min(max(h, minW / a), room, b.width / a)
            w = h * a
        } else {
            let room = grip.movesMinX ? r.maxX - b.minX : b.maxX - r.minX
            w = min(max(w, minW), room, b.height * a)
            h = w / a
        }
        var x = grip.movesMinX ? r.maxX - w : (grip.movesMaxX ? r.minX : r.midX - w / 2)
        var y = grip.movesMinY ? r.maxY - h : (grip.movesMaxY ? r.minY : r.midY - h / 2)
        x = min(max(x, b.minX), b.maxX - w)
        y = min(max(y, b.minY), b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The biggest rect of `aspect` that fits in `b`, centered on `center` as far as it can be.
    static func largest(aspect a: CGFloat, in b: CGRect, around center: CGPoint) -> CGRect {
        var w = b.width
        var h = w / a
        if h > b.height {
            h = b.height
            w = h * a
        }
        let x = min(max(center.x - w / 2, b.minX), b.maxX - w)
        let y = min(max(center.y - h / 2, b.minY), b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Orange outline with square corner grips and pill edge grips (the original's crop look).
    /// Drag inside to move, drag a grip to resize. Works in the canvas's points.
    struct RectEditor: View {
        var rect: CGRect
        var bounds: CGRect
        var aspect: CGFloat? = nil
        var minSize = CGSize(width: 16, height: 16)
        var space: String
        var onChange: (CGRect) -> Void
        var onEnd: () -> Void = {}
        @State private var origin: CGRect?

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .contentShape(Rectangle())
                    .pointerStyle(origin == nil ? .grabIdle : .grabActive)
                    .gesture(drag(nil))
                    .position(x: rect.midX, y: rect.midY)
                Rectangle()
                    .strokeBorder(Look.orange, lineWidth: 2)
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                ForEach(Grip.allCases, id: \.self) { grip in
                    if grip.isCorner || showsEdge(grip) {
                        gripView(grip)
                            .pointerStyle(grip.pointer)
                            .gesture(drag(grip))
                            .position(grip.point(in: rect))
                    }
                }
            }
        }

        private func showsEdge(_ grip: Grip) -> Bool {
            grip.isHorizontalEdge ? rect.width >= 56 : rect.height >= 56
        }

        @ViewBuilder
        private func gripView(_ grip: Grip) -> some View {
            if grip.isCorner {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Look.orange)
                    .frame(width: 10, height: 10)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            } else {
                Capsule()
                    .fill(Look.orange)
                    .frame(width: grip.isHorizontalEdge ? 22 : 5, height: grip.isHorizontalEdge ? 5 : 22)
                    .frame(width: grip.isHorizontalEdge ? 30 : 14, height: grip.isHorizontalEdge ? 14 : 30)
                    .contentShape(Rectangle())
            }
        }

        private func drag(_ grip: Grip?) -> some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    let start = origin ?? rect
                    if origin == nil { origin = rect }
                    if let grip {
                        onChange(VideoToolKit.resize(start, grip: grip, by: value.translation, within: bounds,
                                                     aspect: aspect, minSize: minSize))
                    } else {
                        onChange(VideoToolKit.move(start, by: value.translation, within: bounds))
                    }
                }
                .onEnded { _ in
                    origin = nil
                    onEnd()
                }
        }
    }

    /// Positions of slider tick marks: AppKit insets them by half the knob, so labels line up.
    @MainActor
    static let sliderTickInset: CGFloat = {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 5, target: nil, action: nil)
        slider.numberOfTickMarks = 6
        slider.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        let inset = slider.rectOfTickMark(at: 0).midX
        return inset > 2 && inset < 30 ? inset : 10
    }()
}
