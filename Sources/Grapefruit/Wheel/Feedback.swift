import AppKit
import AVFoundation

/// The tick you hear (and feel on a Force Touch trackpad) when a petal lights up.
/// The sound is synthesized: a short, soft wooden click.
@MainActor
final class Feedback {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    private var shutdown: DispatchWorkItem?

    /// Warm up the audio engine when a wheel opens so the first tick isn't late.
    func prepare() {
        shutdown?.cancel()
        guard Settings.shared.playSounds, engine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return
        }
        self.engine = engine
        self.player = player
        self.buffer = Self.makeTick(format: format)
    }

    func tick() {
        if Settings.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guard Settings.shared.playSounds else { return }
        if engine == nil { prepare() }
        guard let player, let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
        if !player.isPlaying { player.play() }
    }

    /// Let the audio engine sleep a while after the wheel closes.
    func idle() {
        shutdown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.player?.stop()
                self?.engine?.stop()
                self?.engine = nil
                self?.player = nil
            }
        }
        shutdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private static func makeTick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.05)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for n in 0..<Int(frames) {
            let t = Double(n) / rate
            let attack = min(1, t / 0.0008)
            let body = sin(2 * .pi * 1_850 * t) * exp(-t / 0.0065)
            let thump = sin(2 * .pi * 920 * t) * exp(-t / 0.011) * 0.55
            data[n] = Float((body + thump) * attack * 0.16)
        }
        return buffer
    }
}
