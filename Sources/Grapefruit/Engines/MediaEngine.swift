import Foundation

/// Audio and video through ffmpeg. Re-wraps without re-encoding whenever the codecs already fit.
enum MediaEngine {
    struct Probe {
        var duration: Double = 0
        var videoCodec: String?
        var audioCodec: String?
        var width = 0
        var height = 0
        var fps: Double = 30
        var audioBits = 16
        var audioChannels = 2
        var sampleRate = 44_100
        var rotation = 0
        var hasVideo: Bool { videoCodec != nil }
        var hasAudio: Bool { audioCodec != nil }
        /// Display size after rotation.
        var displaySize: (Int, Int) { abs(rotation) % 180 == 90 ? (height, width) : (width, height) }
    }

    static func probe(_ url: URL, ctx: JobContext? = nil) throws -> Probe {
        let ffprobe = try Binaries.require(Binaries.ffprobe, "ffmpeg")
        let result = try Shell.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], ctx: ctx)
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw JobError.failed("Couldn't read this file's media info.")
        }
        var p = Probe()
        if let format = json["format"] as? [String: Any], let d = format["duration"] as? String {
            p.duration = Double(d) ?? 0
        }
        for stream in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = stream["codec_type"] as? String
            let codec = stream["codec_name"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            let isCover = (disposition?["attached_pic"] as? Int) == 1
            if type == "video", p.videoCodec == nil, !isCover {
                p.videoCodec = codec
                p.width = stream["width"] as? Int ?? 0
                p.height = stream["height"] as? Int ?? 0
                if let rate = stream["avg_frame_rate"] as? String ?? stream["r_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0, parts[0] > 0 { p.fps = parts[0] / parts[1] }
                }
                if let tags = stream["tags"] as? [String: Any], let r = tags["rotate"] as? String, let v = Int(r) {
                    p.rotation = v
                }
                for side in (stream["side_data_list"] as? [[String: Any]]) ?? [] {
                    if let r = side["rotation"] as? Int { p.rotation = r }
                    if let r = side["rotation"] as? Double { p.rotation = Int(r) }
                }
                if p.duration == 0, let d = stream["duration"] as? String { p.duration = Double(d) ?? 0 }
            } else if type == "audio", p.audioCodec == nil {
                p.audioCodec = codec
                p.audioChannels = stream["channels"] as? Int ?? 2
                p.sampleRate = Int(stream["sample_rate"] as? String ?? "") ?? 44_100
                let raw = Int(stream["bits_per_raw_sample"] as? String ?? "") ?? 0
                let sampleFormat = stream["sample_fmt"] as? String ?? ""
                if raw > 16 || (codec ?? "").hasPrefix("pcm_s24") || (codec ?? "").hasPrefix("pcm_s32")
                    || ((codec == "flac" || codec == "alac") && sampleFormat.hasPrefix("s32")) {
                    p.audioBits = 24
                }
                if p.duration == 0, let d = stream["duration"] as? String { p.duration = Double(d) ?? 0 }
            }
        }
        return p
    }

    /// Runs ffmpeg and reports progress from its `-progress` feed.
    static func ffmpeg(_ arguments: [String], duration: Double, ctx: JobContext, progressRange: ClosedRange<Double> = 0...1) throws {
        let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
        let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        let span = progressRange.upperBound - progressRange.lowerBound
        try Shell.run(ffmpeg, args, ctx: ctx, collectOutput: false) { line in
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                guard duration > 0, let us = Double(line.split(separator: "=").last ?? "") else { return }
                ctx.progress(progressRange.lowerBound + span * min(1, us / 1_000_000 / duration))
            } else if line == "progress=end" {
                ctx.progress(progressRange.upperBound)
            }
        }
    }

    // MARK: Conversion

    static func convert(_ src: URL, format: String, to target: String, ctx: JobContext) throws -> [URL] {
        let info = try probe(src, ctx: ctx)
        let out = ctx.output(Output.name(src, ext: Catalog.fileExtension(for: target)))
        let input = ["-i", src.path]

        if Catalog.audio.contains(target) {
            guard info.hasAudio else { throw JobError.failed("This file has no sound to convert.") }
            try ffmpeg(input + audioArguments(target, info) + [out.path], duration: info.duration, ctx: ctx)
            return [out]
        }
        if target == "gif" {
            guard info.hasVideo else { throw JobError.failed("This file has no picture to turn into a GIF.") }
            let filter = "fps=15,scale='min(960,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
            try ffmpeg(input + ["-map", "0:v:0", "-vf", filter, "-loop", "0", out.path],
                       duration: info.duration, ctx: ctx)
            return [out]
        }
        guard info.hasVideo else { throw JobError.failed("This file has no video to convert.") }

        // Same codecs, new box: copy the streams, done in seconds.
        if canCopy(info, into: target) {
            var args = input + ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-map_metadata", "0"]
            if target == "mp4" || target == "mov" {
                args += ["-movflags", "+faststart"]
                if info.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
            }
            do {
                try ffmpeg(args + [out.path], duration: info.duration, ctx: ctx)
                return [out]
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: out)
                // Fall through to a full encode.
            }
        }
        try ffmpeg(input + videoArguments(target, info, fromGIF: format == "gif") + [out.path],
                   duration: info.duration, ctx: ctx)
        return [out]
    }

    static func audioArguments(_ target: String, _ info: Probe) -> [String] {
        var a = ["-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "0"]
        let hiRes = info.audioBits > 16
        switch target {
        case "mp3": a += ["-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"]
        case "m4a":
            if info.audioCodec == "aac" || info.audioCodec == "alac" { a += ["-c:a", "copy"] }
            else { a += ["-c:a", "aac_at", "-b:a", "256k"] }
        case "wav": a += ["-c:a", hiRes ? "pcm_s24le" : "pcm_s16le"]
        case "aiff": a += ["-c:a", hiRes ? "pcm_s24be" : "pcm_s16be"]
        case "flac": a += ["-c:a", "flac", "-compression_level", "5"]
        case "ogg": a += ["-c:a", "libvorbis", "-q:a", "6"]
        case "opus": a += ["-c:a", "libopus", "-b:a", "160k", "-vbr", "on"]
        case "wma": a += ["-c:a", "wmav2", "-b:a", "192k"]
        default: break
        }
        return a
    }

    static func canCopy(_ info: Probe, into target: String) -> Bool {
        let v = info.videoCodec ?? ""
        let a = info.audioCodec
        switch target {
        case "mp4":
            return ["h264", "hevc", "av1", "mpeg4"].contains(v) && (a == nil || ["aac", "mp3", "alac", "ac3", "eac3", "opus"].contains(a!))
        case "mov":
            return ["h264", "hevc", "prores", "mpeg4", "mjpeg"].contains(v) && (a == nil || ["aac", "mp3", "alac", "ac3", "pcm_s16le", "pcm_s24le"].contains(a!))
        case "mkv":
            return !["wmv1", "wmv2", "wmv3", "gif", "rawvideo"].contains(v)
        case "webm":
            return ["vp8", "vp9", "av1"].contains(v) && (a == nil || ["opus", "vorbis"].contains(a!))
        default:
            return false
        }
    }

    static func videoArguments(_ target: String, _ info: Probe, fromGIF: Bool) -> [String] {
        var a = ["-map", "0:v:0"]
        if info.hasAudio && !fromGIF { a += ["-map", "0:a:0?"] }
        a += ["-map_metadata", "0", "-sn", "-dn"]
        // Most encoders want even dimensions.
        let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        switch target {
        case "mp4", "mov", "mkv":
            a += ["-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-vf", even]
            if info.hasAudio && !fromGIF { a += ["-c:a", "aac_at", "-b:a", "192k"] }
            if target != "mkv" { a += ["-movflags", "+faststart"] }
        case "webm":
            a += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-deadline", "good", "-cpu-used", "4",
                  "-row-mt", "1", "-pix_fmt", "yuv420p", "-vf", even]
            if info.hasAudio && !fromGIF { a += ["-c:a", "libopus", "-b:a", "128k"] }
        case "avi":
            a += ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "XVID", "-pix_fmt", "yuv420p", "-vf", even]
            if info.hasAudio && !fromGIF { a += ["-c:a", "libmp3lame", "-q:a", "3"] }
        case "wmv":
            a += ["-c:v", "wmv2", "-q:v", "3", "-vf", even]
            if info.hasAudio && !fromGIF { a += ["-c:a", "wmav2", "-b:a", "192k"] }
        default:
            break
        }
        return a
    }
}
