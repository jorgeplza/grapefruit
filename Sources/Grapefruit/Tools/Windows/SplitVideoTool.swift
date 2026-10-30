import SwiftUI

private typealias Kit = VideoToolKit

/// Split Video: add split points on the timeline (at the playhead, or evenly) and save every
/// section as its own clip, "name 1.ext", "name 2.ext"..., in a new "name Clips" folder.
struct SplitVideoTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var player: Kit.Player
    @State private var thumbs = Kit.Thumbnails()
    @State private var link = Kit.WindowLink()
    @State private var points: [Kit.SplitPoint] = []
    @State private var equalClips = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let previewHeight: CGFloat

    /// The strip: a lane for the playhead knob, the frames, a lane for the marker knobs.
    private static let stripHeight: CGFloat = 44

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _player = State(initialValue: Kit.Player(url: session.url))
        previewHeight = Kit.previewHeight(340, rest: 310, anchor: session.anchor)
    }

    /// The shortest clip a split may leave.
    private var minGap: Double { max(player.frameDuration, 0.1) }

    private var maxClips: Int {
        guard player.duration > 0 else { return 2 }
        return max(2, min(50, Int((player.duration / minGap).rounded(.down))))
    }

    /// Where "Add Split" would cut: the start of the frame on screen.
    private var cutHere: Double? {
        guard player.isReady else { return nil }
        let t = player.frameStart(player.time)
        guard t >= minGap - 0.0005, t <= player.duration - minGap + 0.0005 else { return nil }
        guard !points.contains(where: { abs($0.time - t) < minGap - 0.0005 }) else { return nil }
        return t
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                Kit.PreviewBox(player: player, height: previewHeight) { _ in EmptyView() }
                HStack {
                    Text(Kit.count(points.count, "split point", "split points"))
                        .font(Kit.Look.caption)
                        .foregroundStyle(ToolStyle.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Button(action: addSplit) {
                        Label("Add Split", systemImage: "scissors")
                    }
                    .disabled(cutHere == nil)
                }
                .padding(.horizontal, Kit.Look.inset)
                .padding(.top, 16)

                Kit.SplitStrip(player: player, thumbs: thumbs, points: $points, minGap: minGap)
                    .frame(height: Kit.SplitStrip.topLane + Self.stripHeight + Kit.SplitStrip.bottomLane)
                    .opacity(player.failure == nil ? 1 : 0.45)
                    .allowsHitTesting(player.isReady)
                    .modifier(Kit.OwnsDrags(link: link))
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 6)

                Kit.Transport(player: player, showsPlay: false)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 2)

                Divider()
                    .padding(.top, 12)

                HStack(spacing: 10) {
                    Text("Equal clips")
                        .font(Kit.Look.label)
                    Spacer()
                    Text("\(equalClips)")
                        .font(Kit.Look.value)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(equalClips)))
                        .animation(Kit.Look.motion(reduceMotion), value: equalClips)
                    Stepper("Equal clips", value: $equalClips, in: 2...maxClips)
                        .labelsHidden()
                    Button("Set", action: setEqualClips)
                }
                .disabled(!player.isReady)
                .padding(.horizontal, Kit.Look.inset)
                .padding(.top, 12)
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Split Video",
                       primaryEnabled: player.isReady && !points.isEmpty, onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) {
            player.stop()
            thumbs.cancel()
        })
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: maxClips) { _, limit in
            if equalClips > limit { equalClips = limit }
        }
    }

    private func addSplit() {
        guard let t = cutHere else { return }
        withAnimation(Kit.Look.motion(reduceMotion)) {
            points.append(Kit.SplitPoint(time: t))
            points.sort { $0.time < $1.time }
        }
        Kit.haptic()
    }

    /// Replaces the splits with `equalClips` clips of the same length, cut on frames.
    private func setEqualClips() {
        guard player.isReady else { return }
        let n = min(equalClips, maxClips)
        let length = player.duration
        var times: [Double] = []
        for i in 1..<n {
            let t = player.nearestBoundary(length * Double(i) / Double(n))
            if t >= minGap, t <= length - minGap, times.allSatisfy({ t - $0 >= minGap - 0.0005 }) { times.append(t) }
        }
        withAnimation(Kit.Look.motion(reduceMotion)) {
            points = times.map { Kit.SplitPoint(time: $0) }
        }
        Kit.haptic()
    }

    private func apply() {
        let src = session.url
        let cuts = points.map(\.time).sorted()
        let duration = player.duration
        let folderName = Output.name(src, suffix: session.tool.outputSuffix, ext: "")
        player.stop()
        let step = JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
            let folder = ctx.output(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try VideoToolKit.split(src, at: cuts, duration: duration, into: folder, ctx: ctx)
            return [folder]
        }
        session.run([step])
    }
}
