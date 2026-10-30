import AppKit
import AVFoundation
import Accelerate
import SwiftUI

/// Shared parts of the audio tool windows (Normalize, Trim, Channels, Visualizer, Bleep):
/// file info, waveform levels, playback, the waveform look, and encoding that keeps each
/// file's format. Everything lives in this namespace so it can't collide with other tools.
enum AudioToolKit {

    // MARK: - Look

    /// Measured from the original windows: 1pt bars on a 3pt pitch, silence drawn as a dotted
    /// line, the loudest bar filling most of its lane, 6pt lane corners.
    enum Look {
        static let bar: CGFloat = 1
        static let pitch: CGFloat = 3
        static let dot: CGFloat = 1.5
        static let fill: CGFloat = 0.84
        static let corner: CGFloat = 6
        static let handle: CGFloat = 10
        /// The grey lane behind a waveform: 238 on the original's 246 window.
        static let lane = Color.primary.opacity(0.033)
        static let grey = Color.primary.opacity(0.3)
        /// The lighter orange the original uses for bleeps and their waveform.
        static let soft = ToolStyle.orange.opacity(0.62)
        static let tint = ToolStyle.orange.opacity(0.1)
        /// "Start 0:00.00", "0:02.00": the original sets lane times in 10pt SF Mono.
        static let clock = Font.system(size: 10, design: .monospaced)

        /// Fast, interruptible spring; nothing at all when Reduce Motion is on.
        static func spring(_ reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.88)
        }
    }

    // MARK: - Text

    /// "0:02.00", or "1:02:03.45" for files that run an hour or more.
    static func clock(_ seconds: Double, hours: Bool = false) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        let cs = Int((value * 100).rounded())
        let h = cs / 360_000
        let m = cs / 6000 % 60
        let s = cs / 100 % 60
        let c = cs % 100
        if hours || h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, c) }
        return String(format: "%d:%02d.%02d", cs / 6000, s, c)
    }

    /// Reads "1:23.45", "83.4" or "1:02:03" back into seconds.
    static func parseClock(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            guard let v = Double(part), v >= 0, v.isFinite else { return nil }
            if i < parts.count - 1, v != v.rounded() { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Negative numbers get a real minus sign: "−16", "−1.5".
    static func signed(_ value: Double, decimals: Int = 0) -> String {
        let text = String(format: "%.\(decimals)f", abs(value))
        let zero = String(format: "%.\(decimals)f", 0.0)
        return value < 0 && text != zero ? "\u{2212}" + text : text
    }

    /// A light tick on Force Touch trackpads, when the user allows haptics.
    @MainActor static func tick() {
        guard Settings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Short, plain wording for files that won't open.
    static func readError(_ error: Error) -> String {
        if case JobError.failed(let message) = error,
           message.contains("isn't installed") || message.hasPrefix("This file has no sound") {
            return message
        }
        return "Couldn't read this file."
    }
}

// MARK: - File info

extension AudioToolKit {
    /// What the windows and encoders need to know about an audio file.
    struct Info: Equatable {
        var duration = 0.0
        var sampleRate = 44_100
        var channels = 2
        var layout = ""
        var codec = ""
        var sampleFormat = ""
        var bits = 16
        var bitRate = 0
        var hasCover = false

        var layoutName: String {
            switch channels {
            case 1: "Mono"
            case 2: "Stereo"
            case 3: "2.1"
            case 4: layout == "quad" ? "Quad" : "4.0"
            case 6: "5.1"
            case 8: "7.1"
            default: "\(channels) channels"
            }
        }

        var isLossless: Bool {
            codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack", "ape", "tta"].contains(codec)
        }
    }

    static func probe(_ url: URL, ctx: JobContext? = nil) throws -> Info {
        let ffprobe = try Binaries.require(Binaries.ffprobe, "ffmpeg")
        let result: Shell.Result
        do {
            result = try Shell.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], ctx: ctx)
        } catch JobError.cancelled {
            throw JobError.cancelled
        } catch {
            // ffprobe's own message names the full path; keep it short and plain.
            throw JobError.failed("Couldn't read this file.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw JobError.failed("Couldn't read this file.")
        }
        func int(_ any: Any?) -> Int {
            if let s = any as? String { return Int(s) ?? Int(Double(s) ?? 0) }
            return any as? Int ?? 0
        }
        func number(_ any: Any?) -> Double {
            if let s = any as? String { return Double(s) ?? 0 }
            return any as? Double ?? 0
        }
        let streams = (json["streams"] as? [[String: Any]]) ?? []
        guard let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw JobError.failed("This file has no sound.")
        }
        let format = json["format"] as? [String: Any]
        var info = Info()
        info.codec = audio["codec_name"] as? String ?? ""
        info.sampleRate = int(audio["sample_rate"])
        info.channels = max(1, int(audio["channels"]))
        info.layout = audio["channel_layout"] as? String ?? ""
        info.sampleFormat = audio["sample_fmt"] as? String ?? ""
        let raw = int(audio["bits_per_raw_sample"])
        let perSample = int(audio["bits_per_sample"])
        if raw > 0 { info.bits = raw } else if perSample > 0 { info.bits = perSample }
        else if info.sampleFormat.hasPrefix("s32") || info.sampleFormat.hasPrefix("flt") { info.bits = 24 }
        info.bits = min(32, max(8, info.bits))
        info.bitRate = int(audio["bit_rate"])
        if info.bitRate == 0, streams.count == 1 { info.bitRate = int(format?["bit_rate"]) }
        info.duration = number(format?["duration"])
        if info.duration <= 0 { info.duration = number(audio["duration"]) }
        info.hasCover = streams.contains {
            $0["codec_type"] as? String == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
        }
        guard info.sampleRate > 0 else { throw JobError.failed("Couldn't read this file.") }
        return info
    }
}

// MARK: - Levels

extension AudioToolKit {
    /// Peak and RMS for every 10 ms of a file, per channel. Files wider than stereo are
    /// mixed down to stereo first. Drives every waveform and the silence detection.
    struct Levels {
        static let blocksPerSecond = 100.0

        let sampleRate: Double
        let blockFrames: Int
        private(set) var peaks: [[Float]]
        private(set) var rms: [[Float]]
        private(set) var frames = 0
        private(set) var maxPeak: Float = 0
        var complete = false

        init(sampleRate: Double, blockFrames: Int, channels: Int) {
            self.sampleRate = sampleRate
            self.blockFrames = blockFrames
            peaks = Array(repeating: [], count: channels)
            rms = Array(repeating: [], count: channels)
        }

        var channels: Int { peaks.count }
        var count: Int { peaks.first?.count ?? 0 }
        var duration: Double { Double(frames) / sampleRate }
        var blockSeconds: Double { Double(blockFrames) / sampleRate }

        /// Adds one block of interleaved float samples.
        mutating func append(_ samples: UnsafePointer<Float>, frames n: Int) {
            guard n > 0 else { return }
            let stride = vDSP_Stride(channels)
            for c in 0..<channels {
                var peak: Float = 0
                var squares: Float = 0
                vDSP_maxmgv(samples + c, stride, &peak, vDSP_Length(n))
                vDSP_svesq(samples + c, stride, &squares, vDSP_Length(n))
                peaks[c].append(peak)
                rms[c].append((squares / Float(n)).squareRoot())
                if peak > maxPeak { maxPeak = peak }
            }
            frames += n
        }

        /// The loudest peak in each of `n` equal slices of `from...to` (seconds).
        /// Slices not decoded yet come back as 0, which draws as silence.
        func bars(_ n: Int, from start: Double = 0, to end: Double? = nil, channel: Int? = nil) -> [Float] {
            guard n > 0 else { return [] }
            var out = [Float](repeating: 0, count: n)
            let stop = end ?? duration
            guard count > 0, stop > start else { return out }
            let first = start / blockSeconds
            let span = (stop - start) / blockSeconds
            let list = channel.map { [$0] } ?? Array(0..<channels)
            for i in 0..<n {
                var lo = Int((first + span * Double(i) / Double(n)).rounded(.down))
                var hi = Int((first + span * Double(i + 1) / Double(n)).rounded(.down))
                if hi <= lo { hi = lo + 1 }
                lo = max(0, lo)
                hi = min(count, hi)
                guard hi > lo else { continue }
                var best: Float = 0
                for c in list where c < channels {
                    peaks[c].withUnsafeBufferPointer { p in
                        var v: Float = 0
                        vDSP_maxv(p.baseAddress! + lo, 1, &v, vDSP_Length(hi - lo))
                        best = max(best, v)
                    }
                }
                out[i] = best
            }
            return out
        }

        private func level(_ block: Int) -> Float {
            var v: Float = 0
            for c in 0..<channels { v = max(v, rms[c][block]) }
            return v
        }

        /// Where sound starts and ends, treating anything under `threshold` (−50 dB) at the ends
        /// as silence and keeping a little air around it. Nil when the whole file is silent.
        func soundBounds(threshold: Float = 0.00316, padding: Double = 0.15) -> ClosedRange<Double>? {
            guard let first = (0..<count).first(where: { level($0) >= threshold }),
                  let last = (0..<count).last(where: { level($0) >= threshold }) else { return nil }
            let start = max(0, Double(first) * blockSeconds - padding)
            let end = min(duration, Double(last + 1) * blockSeconds + padding)
            return start...max(start, end)
        }

        /// Average RMS of the parts that aren't silent. Used to pitch the bleep tone at voice level.
        func activeRMS(threshold: Float = 0.00316) -> Float {
            var sum: Double = 0
            var n = 0
            for b in 0..<count {
                let v = level(b)
                if v >= threshold {
                    sum += Double(v * v)
                    n += 1
                }
            }
            return n == 0 ? 0 : Float((sum / Double(n)).squareRoot())
        }
    }

    /// Decodes the whole file through ffmpeg into `Levels`. Calls `partial` now and then with
    /// what's been read so far, so long files can draw as they load.
    static func decodeLevels(_ url: URL, info: Info, ctx: JobContext?,
                             partial: ((Levels) -> Void)? = nil) throws -> Levels {
        let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
        let channels = info.channels == 1 ? 1 : 2
        let rate = Double(info.sampleRate)
        let blockFrames = max(1, Int((rate / Levels.blocksPerSecond).rounded()))
        let blockBytes = blockFrames * channels * MemoryLayout<Float>.size
        var levels = Levels(sampleRate: rate, blockFrames: blockFrames, channels: channels)
        var pending = Data()
        var lastPartial = Date()
        let args = ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path,
                    "-map", "0:a:0", "-vn", "-sn", "-dn", "-ac", String(channels), "-ar", String(info.sampleRate),
                    "-f", "f32le", "-c:a", "pcm_f32le", "pipe:1"]
        try stream(ffmpeg, args, ctx: ctx) { chunk in
            pending.append(chunk)
            let whole = pending.count / blockBytes
            guard whole > 0 else { return }
            pending.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for b in 0..<whole {
                    levels.append(base + b * blockFrames * channels, frames: blockFrames)
                }
            }
            pending.removeFirst(whole * blockBytes)
            if let partial, Date().timeIntervalSince(lastPartial) > 0.2 {
                lastPartial = Date()
                partial(levels)
            }
        }
        let tail = pending.count / (channels * MemoryLayout<Float>.size)
        if tail > 0 {
            pending.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                levels.append(base, frames: tail)
            }
        }
        levels.complete = true
        guard levels.frames > 0 else { throw JobError.failed("This file has no sound.") }
        return levels
    }
}

// MARK: - Processes

extension AudioToolKit {
    /// A value shared between threads.
    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
    }

    /// Runs a tool and hands its standard output over in chunks as it arrives.
    /// Stops the tool when the context is cancelled or `onData` throws.
    static func stream(_ executable: URL, _ arguments: [String], ctx: JobContext?,
                       onData: (Data) throws -> Void) throws {
        try ctx?.checkCancelled()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let errors = Locked(Data())
        try process.run()
        ctx?.track(process)
        defer { ctx?.untrack(process) }
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? err.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                errors.mutate { data in
                    data.append(chunk)
                    if data.count > 32_000 { data.removeFirst(data.count - 32_000) }
                }
            }
            drained.signal()
        }
        do {
            let handle = out.fileHandleForReading
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try onData(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            drained.wait()
            try ctx?.checkCancelled()
            throw error
        }
        process.waitUntilExit()
        drained.wait()
        try ctx?.checkCancelled()
        if process.terminationStatus != 0 {
            throw JobError.failed(Shell.cleanError(String(decoding: errors.value, as: UTF8.self),
                                                   tool: executable.lastPathComponent))
        }
    }

    /// A throwaway context for work a window does on its own (loading, measuring),
    /// so closing the window can stop it.
    static func windowContext() -> JobContext {
        JobContext(scratch: FileManager.default.temporaryDirectory) { _ in }
    }
}

// MARK: - Source

extension AudioToolKit {
    /// One file as a window sees it: info first, then levels that fill in as the file decodes.
    @MainActor
    final class Source: ObservableObject {
        enum Phase: Equatable { case loading, ready, failed(String) }

        let url: URL
        @Published private(set) var info: Info?
        @Published private(set) var levels: Levels?
        @Published private(set) var phase = Phase.loading
        private let ctx = AudioToolKit.windowContext()
        private var cache: [Int: [Float]] = [:]

        init(_ url: URL) {
            self.url = url
            load()
        }

        deinit { ctx.cancel() }

        var name: String { url.lastPathComponent }
        var isReady: Bool { phase == .ready }
        var failure: String? {
            if case .failed(let message) = phase { return message }
            return nil
        }

        /// Exact once decoded; ffprobe's estimate before that.
        var duration: Double {
            if let levels, levels.complete { return levels.duration }
            return max(info?.duration ?? 0, levels?.duration ?? 0)
        }

        /// Clocks switch to h:mm:ss for long files.
        var longForm: Bool { duration >= 3600 }
        var maxPeak: Float { levels?.maxPeak ?? 0 }
        var channels: Int { info?.channels ?? 2 }

        func clock(_ seconds: Double) -> String { AudioToolKit.clock(seconds, hours: longForm) }

        /// Loudest peak in each of `n` slices of the whole file (linear, 1 = full scale).
        func bars(_ n: Int, channel: Int? = nil) -> [Float] {
            let key = n * 4 + (channel.map { $0 + 1 } ?? 0)
            if let hit = cache[key] { return hit }
            guard let levels else { return Array(repeating: 0, count: max(0, n)) }
            let values = levels.bars(n, from: 0, to: duration, channel: channel)
            cache[key] = values
            return values
        }

        func cancel() { ctx.cancel() }

        private func load() {
            let url = url
            let ctx = ctx
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let info = try AudioToolKit.probe(url, ctx: ctx)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.info = info } }
                    let levels = try AudioToolKit.decodeLevels(url, info: info, ctx: ctx) { partial in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(partial) } }
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(levels) } }
                } catch JobError.cancelled {
                    return
                } catch {
                    let message = AudioToolKit.readError(error)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.phase = .failed(message) } }
                }
            }
        }

        private func show(_ new: Levels) {
            guard phase == .loading else { return }
            levels = new
            cache = [:]
            if new.complete { phase = .ready }
        }
    }
}

// MARK: - Playback

extension AudioToolKit {
    /// A stereo stretch of audio on its way to the speakers. Tools rewrite it in place
    /// (gains, muted ranges, a bleep) so what you hear matches what the tool will save.
    struct Chunk {
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let frames: Int
        /// Seconds into the file of the first frame.
        let start: Double
        let sampleRate: Double
    }

    /// Plays a file (or part of it) through a small AVAudioEngine graph, a few short chunks
    /// ahead, so settings changes are heard almost at once. Stops when the window closes.
    @MainActor
    final class Player: ObservableObject {
        @Published private(set) var isPlaying = false
        /// Where the playhead rests while paused, in seconds.
        @Published private(set) var parked: Double = 0
        /// Which preview is playing, for windows with more than one ("left", "output"...).
        @Published private(set) var tag: String?
        @Published private(set) var unavailable = false

        private let core: PlayerCore
        private var rewind: Double?
        private var session = 0

        init(url: URL) {
            core = PlayerCore(url: url)
            core.onStopped = { [weak self] time in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isPlaying else { return }
                        self.isPlaying = false
                        self.tag = nil
                        self.parked = time
                    }
                }
            }
        }

        deinit { core.shutdown() }

        /// Runs on the audio thread for every chunk. Read settings through a `Locked` box.
        func setProcessor(_ process: ((Chunk) -> Void)?) { core.setProcessor(process) }

        /// The playhead, for views redrawn every frame while playing.
        var time: Double {
            guard isPlaying else { return parked }
            return core.currentTime() ?? parked
        }

        /// Plays `from...to`. At the end the playhead goes back to `rewindTo` (or stays at the end).
        func play(from start: Double? = nil, to end: Double? = nil, rewindTo: Double? = nil, tag: String? = nil) {
            let begin = max(0, start ?? parked)
            session += 1
            let mine = session
            rewind = rewindTo
            parked = begin
            isPlaying = true
            self.tag = tag
            core.start(from: begin, to: end) { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.session == mine else { return }
                        self.isPlaying = false
                        self.tag = nil
                        switch result {
                        case .finished(let end): self.parked = self.rewind ?? end
                        case .failed: self.unavailable = true
                        }
                    }
                }
            }
        }

        func pause() {
            guard isPlaying else { return }
            parked = core.currentTime() ?? parked
            session += 1
            isPlaying = false
            tag = nil
            core.halt()
        }

        /// Moves the playhead; keeps playing from there if it was playing.
        func seek(_ seconds: Double, end: Double? = nil) {
            if isPlaying {
                play(from: seconds, to: end, rewindTo: rewind, tag: tag)
            } else {
                parked = max(0, seconds)
            }
        }

        /// Re-renders from the current spot so a changed setting is heard right away.
        func refresh(end: Double? = nil) {
            guard isPlaying else { return }
            play(from: core.currentTime() ?? parked, to: end, rewindTo: rewind, tag: tag)
        }

        /// Stops and lets go of the audio device. Safe to call more than once.
        func close() {
            session += 1
            isPlaying = false
            tag = nil
            core.shutdown()
        }
    }

    /// The thread-confined half of `Player`: everything here runs on `queue`.
    final class PlayerCore: @unchecked Sendable {
        enum Result { case finished(Double), failed }

        private static let chunkFrames: AVAudioFrameCount = 2048
        private static let ahead = 4

        private let url: URL
        private let queue = DispatchQueue(label: "grapefruit.audio.preview", qos: .userInitiated)
        private var engine: AVAudioEngine?
        private var file: AVAudioFile?
        private var converter: AVAudioConverter?
        private var input: AVAudioPCMBuffer?
        private var output: AVAudioFormat?
        private var transcoded: URL?
        private var observer: NSObjectProtocol?
        private var generation = 0
        private var nextFrame: AVAudioFramePosition = 0
        private var endFrame: AVAudioFramePosition = 0
        private var inFlight = 0
        private var done: ((Result) -> Void)?
        private var closed = false

        /// Read from the main thread for the playhead.
        private struct Clock {
            var node: AVAudioPlayerNode?
            var start: Double = 0
            var running = false
        }
        private let clock = Locked(Clock())
        private let processor = Locked<((Chunk) -> Void)?>(nil)
        var onStopped: ((Double) -> Void)?

        init(url: URL) { self.url = url }

        func setProcessor(_ process: ((Chunk) -> Void)?) { processor.value = process }

        func currentTime() -> Double? {
            let c = clock.value
            guard c.running else { return nil }
            guard let node = c.node, let now = node.lastRenderTime, now.isSampleTimeValid,
                  let t = node.playerTime(forNodeTime: now), t.sampleRate > 0 else { return c.start }
            return c.start + max(0, Double(t.sampleTime)) / t.sampleRate
        }

        func start(from seconds: Double, to end: Double?, done: @escaping (Result) -> Void) {
            queue.async { [self] in
                guard !closed else { return }
                generation += 1
                let gen = generation
                self.done = nil
                do {
                    try open()
                } catch {
                    done(.failed)
                    return
                }
                guard let engine, let file, let node = clock.value.node else { return }
                node.stop()
                inFlight = 0
                let rate = file.processingFormat.sampleRate
                let total = file.length
                nextFrame = min(max(0, AVAudioFramePosition(seconds * rate)), total)
                endFrame = end.map { min(max(nextFrame, AVAudioFramePosition($0 * rate)), total) } ?? total
                self.done = done
                if !engine.isRunning {
                    do { try engine.start() } catch {
                        self.done = nil
                        done(.failed)
                        return
                    }
                }
                let begin = Double(nextFrame) / rate
                pump(gen)
                guard gen == generation else { return }
                clock.mutate { $0.start = begin; $0.running = true }
                node.play()
            }
        }

        /// Pause: stop the node, keep the engine around for the next play.
        func halt() {
            queue.async { [self] in
                generation += 1
                done = nil
                clock.mutate { $0.running = false }
                clock.value.node?.stop()
                engine?.pause()
            }
        }

        func shutdown() {
            queue.async { [self] in
                guard !closed else { return }
                closed = true
                generation += 1
                done = nil
                clock.mutate { $0.running = false }
                clock.value.node?.stop()
                engine?.stop()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                engine = nil
                file = nil
                clock.mutate { $0.node = nil }
                if let transcoded { try? FileManager.default.removeItem(at: transcoded) }
                transcoded = nil
            }
        }

        private func open() throws {
            if engine != nil { return }
            let file: AVAudioFile
            if let direct = try? AVAudioFile(forReading: url), direct.length > 0 {
                file = direct
            } else {
                // Rare encodings Core Audio can't read: make a temporary copy it can.
                file = try AVAudioFile(forReading: transcode())
            }
            let format = file.processingFormat
            guard let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2),
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else {
                throw JobError.failed("Can't play this file.")
            }
            if format.channelCount > 2 {
                converter = AVAudioConverter(from: format, to: stereo)
                converter?.downmix = true
            }
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: stereo)
            engine.prepare()
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: engine, queue: nil) { [weak self] _ in
                self?.interrupted()
            }
            self.file = file
            self.input = input
            self.output = stereo
            self.engine = engine
            clock.mutate { $0.node = node }
        }

        /// The output device changed under us: stop cleanly where we were.
        private func interrupted() {
            let time = currentTime()
            queue.async { [self] in
                guard clock.value.running else { return }
                generation += 1
                done = nil
                clock.mutate { $0.running = false }
                clock.value.node?.stop()
                onStopped?(time ?? 0)
            }
        }

        private func transcode() throws -> URL {
            let ffmpeg = try Binaries.require(Binaries.ffmpeg, "ffmpeg")
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("grapefruit-preview-\(UUID().uuidString).flac")
            try Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", url.path, "-map", "0:a:0",
                                   "-vn", "-c:a", "flac", "-compression_level", "0", out.path])
            transcoded = out
            return out
        }

        private func pump(_ gen: Int) {
            guard gen == generation, let file, let input, let output, let node = clock.value.node else { return }
            while inFlight < Self.ahead && nextFrame < endFrame {
                let want = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunkFrames), endFrame - nextFrame))
                do {
                    file.framePosition = nextFrame
                    try file.read(into: input, frameCount: want)
                } catch {
                    endFrame = nextFrame
                    break
                }
                let got = input.frameLength
                guard got > 0, let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: got) else {
                    endFrame = nextFrame
                    break
                }
                chunk.frameLength = got
                stereo(from: input, into: chunk)
                if let process = processor.value, let channels = chunk.floatChannelData {
                    process(Chunk(left: channels[0], right: channels[1], frames: Int(got),
                                  start: Double(nextFrame) / output.sampleRate, sampleRate: output.sampleRate))
                }
                nextFrame += AVAudioFramePosition(got)
                inFlight += 1
                node.scheduleBuffer(chunk, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard gen == self.generation else { return }
                        self.inFlight -= 1
                        self.pump(gen)
                    }
                }
            }
            if nextFrame >= endFrame && inFlight == 0 { finish(gen) }
        }

        private func finish(_ gen: Int) {
            guard gen == generation else { return }
            generation += 1
            let end = Double(endFrame) / (output?.sampleRate ?? 44_100)
            clock.mutate { $0.running = false }
            clock.value.node?.stop()
            engine?.pause()
            let callback = done
            done = nil
            callback?(.finished(end))
        }

        /// Mono plays in both ears, stereo as is, anything wider is mixed down.
        private func stereo(from source: AVAudioPCMBuffer, into target: AVAudioPCMBuffer) {
            let n = Int(source.frameLength)
            guard let src = source.floatChannelData, let dst = target.floatChannelData else { return }
            switch source.format.channelCount {
            case 1:
                dst[0].update(from: src[0], count: n)
                dst[1].update(from: src[0], count: n)
            case 2:
                dst[0].update(from: src[0], count: n)
                dst[1].update(from: src[1], count: n)
            default:
                if let converter {
                    try? converter.convert(to: target, from: source)
                    target.frameLength = AVAudioFrameCount(n)
                }
            }
        }
    }
}

// MARK: - Views

extension AudioToolKit {
    /// The waveform: rounded bars centred on the lane, silence as dots. `scale` animates,
    /// so gain and volume changes spring instead of snapping.
    struct Bars: Shape {
        var values: [Float]
        /// Multiplies every value; 1 / max peak fills the lane, a gain shows levels after it.
        var scale: Double = 1
        /// Values are clipped here after scaling (a true-peak ceiling, say). 1 is full scale.
        var ceiling: Double = 1
        /// Only draw these bars (for two-tone waveforms).
        var only: Range<Int>?
        var bar: CGFloat = Look.bar
        var pitch: CGFloat = Look.pitch
        var dot: CGFloat = Look.dot
        var fill: CGFloat = Look.fill

        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(scale, ceiling) }
            set {
                scale = newValue.first
                ceiling = newValue.second
            }
        }

        /// How many bars fit in `width`.
        static func count(for width: CGFloat, bar: CGFloat = Look.bar, pitch: CGFloat = Look.pitch) -> Int {
            guard width > bar else { return 1 }
            return Int((width - bar) / pitch) + 1
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let n = values.count
            guard n > 0 else { return path }
            let used = CGFloat(n - 1) * pitch + bar
            let x0 = rect.minX + (rect.width - used) / 2
            let range = only.map { $0.clamped(to: 0..<n) } ?? 0..<n
            let radius = bar / 2
            for i in range {
                let v = min(Double(values[i]) * scale, ceiling)
                let h = max(dot, CGFloat(max(0, v)) * rect.height * fill)
                let r = CGRect(x: x0 + CGFloat(i) * pitch, y: rect.midY - h / 2, width: bar, height: h)
                path.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius))
            }
            return path
        }

        /// Bar index under an x position within a lane of `width`.
        static func index(at x: CGFloat, count n: Int, width: CGFloat, pitch: CGFloat = Look.pitch, bar: CGFloat = Look.bar) -> Int {
            let used = CGFloat(n - 1) * pitch + bar
            let x0 = (width - used) / 2
            return Int(((x - x0) / pitch).rounded(.down))
        }
    }

    /// Bars from index `lo` up to (not including) `hi` fall inside `fraction` of the lane.
    static func barRange(_ fraction: ClosedRange<Double>, count n: Int) -> Range<Int> {
        guard n > 0 else { return 0..<0 }
        let lo = Int((fraction.lowerBound * Double(n)).rounded())
        let hi = Int((fraction.upperBound * Double(n)).rounded())
        let a = min(max(0, lo), n)
        return a..<min(max(a, hi), n)
    }

    /// Redraws every display frame while `active`: for playheads and running clocks only,
    /// so the rest of the window stays still.
    struct Live<Content: View>: View {
        var active: Bool
        @ViewBuilder var content: () -> Content

        var body: some View {
            TimelineView(.animation(minimumInterval: nil, paused: !active)) { _ in content() }
        }
    }

    /// Play/pause glyph that morphs between the two.
    struct PlayGlyph: View {
        var playing: Bool
        var size: CGFloat = 12

        var body: some View {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 6, height: size + 6)
        }
    }

    /// The bare ▶ button the original puts under a waveform.
    struct PlainPlayButton: View {
        var playing: Bool
        var enabled = true
        var action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                PlayGlyph(playing: playing, size: 12)
                    .foregroundStyle(Color.primary.opacity(enabled ? (hovering ? 1 : 0.8) : 0.3))
                    .frame(width: 26, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering && enabled ? 0.07 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hovering = $0 }
            .help(playing ? "Pause" : "Play")
            .accessibilityLabel(playing ? "Pause" : "Play")
        }
    }

    /// A thin playhead with a soft shadow.
    struct Playhead: View {
        var color: Color = .white
        var width: CGFloat = 2

        var body: some View {
            Capsule()
                .fill(color)
                .frame(width: width)
                .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 0)
                .allowsHitTesting(false)
        }
    }

    /// What a lane shows while its file decodes: the dotted silence line, breathing gently.
    struct LoadingLine: View {
        var color: Color = Look.grey
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var bright = false

        var body: some View {
            GeometryReader { geo in
                Bars(values: Array(repeating: 0, count: Bars.count(for: geo.size.width)))
                    .fill(color)
                    .opacity(bright ? 0.9 : 0.35)
            }
            .onAppear {
                guard !reduceMotion else { bright = true; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
            }
            .accessibilityLabel("Loading waveform")
        }
    }

    /// A short message in place of a waveform when the file can't be read.
    struct LaneMessage: View {
        var text: String
        var symbol = "exclamationmark.triangle"

        var body: some View {
            Label(text, systemImage: symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Calls `onClose` when the window holding this view closes, so playback and background
    /// work stop with it.
    struct CloseHook: NSViewRepresentable {
        var onClose: () -> Void

        func makeNSView(context: Context) -> HookView {
            let view = HookView()
            view.onClose = onClose
            return view
        }

        func updateNSView(_ view: HookView, context: Context) {
            view.onClose = onClose
        }

        final class HookView: NSView {
            var onClose: () -> Void = {}
            private var token: NSObjectProtocol?

            override func viewWillMove(toWindow newWindow: NSWindow?) {
                super.viewWillMove(toWindow: newWindow)
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, token == nil else { return }
                token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                }
            }
        }
    }

    /// Space plays and pauses, like every media app.
    struct SpaceKey: View {
        var action: () -> Void

        var body: some View {
            Button("", action: action)
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// A caption row with a file name that truncates in the middle and a value on the right.
    struct NameRow: View {
        var name: String
        var value: String?

        var body: some View {
            HStack(spacing: 12) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                Spacer(minLength: 0)
                if let value {
                    Text(value)
                        .monospacedDigit()
                        .fixedSize()
                        .contentTransition(.numericText())
                }
            }
            .font(ToolStyle.label)
            .foregroundStyle(ToolStyle.secondary)
        }
    }
}

// MARK: - Encoding

extension AudioToolKit {
    /// Output stream options that keep the source's format: same codec family, sample rate,
    /// bit depth, a bitrate at least as high as the original's, tags and cover art.
    static func encoderArguments(for info: Info, ext: String, coverFromInput input: Int = 0) -> [String] {
        let e = ext.lowercased()
        var a = ["-map", "\(input):a:0"]
        let keepsCover = info.hasCover && ["mp3", "m4a", "m4b", "flac"].contains(e)
        if keepsCover {
            a += ["-map", "\(input):v?", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        } else {
            a += ["-vn"]
        }
        a += ["-sn", "-dn", "-map_metadata", String(input)]

        func kbps(floor: Int = 96) -> String {
            let source = info.bitRate / 1000
            let steps = [96, 112, 128, 160, 192, 224, 256, 320]
            let pick = steps.first { $0 >= max(floor, source) } ?? 320
            return "\(pick)k"
        }

        switch e {
        case "mp3":
            if info.bitRate > 0 { a += ["-c:a", "libmp3lame", "-b:a", kbps()] }
            else { a += ["-c:a", "libmp3lame", "-q:a", "2"] }
            a += ["-id3v2_version", "3"]
        case "m4a", "m4b", "mp4", "aac":
            if info.codec == "alac" {
                a += ["-c:a", "alac", "-sample_fmt", info.bits > 16 ? "s32p" : "s16p"]
            } else {
                a += ["-c:a", "aac_at", "-b:a", kbps(floor: 128)]
            }
            if e != "aac" { a += ["-movflags", "+faststart"] }
        case "wav", "wave":
            a += ["-c:a", pcmCodec(info, bigEndian: false)]
        case "aif", "aiff", "aifc":
            a += ["-c:a", pcmCodec(info, bigEndian: true)]
        case "flac":
            a += ["-c:a", "flac", "-compression_level", "5"]
            a += info.bits > 16 ? ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"] : ["-sample_fmt", "s16"]
        case "ogg", "oga":
            a += ["-c:a", "libvorbis", "-q:a", "6"]
        case "opus":
            a += ["-c:a", "libopus", "-b:a", "160k", "-vbr", "on"]
        default:
            a += ["-c:a", "pcm_s16le"]
        }
        a += ["-ar", String(info.sampleRate)]
        return a
    }

    private static func pcmCodec(_ info: Info, bigEndian: Bool) -> String {
        let end = bigEndian ? "be" : "le"
        if info.codec.hasPrefix("pcm_") {
            if info.codec.hasPrefix("pcm_f32") || info.codec.hasPrefix("pcm_f64") { return "pcm_f32" + end }
            if info.codec == "pcm_u8" && !bigEndian { return "pcm_u8" }
            if info.codec.hasPrefix("pcm_s32") { return "pcm_s32" + end }
        }
        return info.bits > 16 ? "pcm_s24" + end : "pcm_s16" + end
    }

    /// The last filter in a chain: back to the source's sample rate, with dither when the
    /// result lands in 16-bit PCM or FLAC. Bleep skips the dither so every sample it doesn't
    /// touch comes back bit for bit.
    static func finishingFilter(for info: Info, ext: String, dither: Bool = true) -> String {
        var f = "aresample=\(info.sampleRate):resampler=soxr"
        let e = ext.lowercased()
        guard info.bits <= 16, !info.codec.hasPrefix("pcm_f"), info.codec != "pcm_u8" else { return f }
        let method = dither ? ":dither_method=triangular_hp" : ""
        if ["wav", "wave", "flac", "aif", "aiff", "aifc"].contains(e) {
            f += ":osf=s16" + method
        } else if info.codec == "alac" {
            f += ":osf=s16p" + method
        }
        return f
    }

    /// Runs ffmpeg over `src` with `filter` and writes `out` in the source's format.
    /// Progress goes into `ctx` across `range`.
    static func render(_ src: URL, info: Info, filter: String?, to out: URL, ctx: JobContext,
                       range: ClosedRange<Double> = 0...1, inputOptions: [String] = [], outputOptions: [String] = []) throws {
        var args = inputOptions + ["-i", src.path]
        args += encoderArguments(for: info, ext: out.pathExtension)
        if let filter, !filter.isEmpty { args += ["-af", filter] }
        args += outputOptions
        let length = outputOptions.firstIndex(of: "-t").flatMap { Double(outputOptions[$0 + 1]) } ?? info.duration
        do {
            try MediaEngine.ffmpeg(args + [out.path], duration: length, ctx: ctx, progressRange: range)
        } catch JobError.cancelled {
            throw JobError.cancelled
        } catch {
            // Some cover art won't go into the new file; keep the sound, drop the picture.
            guard info.hasCover else { throw error }
            try? FileManager.default.removeItem(at: out)
            var plain = info
            plain.hasCover = false
            try render(src, info: plain, filter: filter, to: out, ctx: ctx, range: range,
                       inputOptions: inputOptions, outputOptions: outputOptions)
        }
    }
}
