import SwiftUI

private typealias Kit = VideoToolKit

/// Video Snapshots: scrub or step to a frame, add it to the strip, and save full-resolution PNGs.
/// One frame is "name Snapshot.png"; several go in "name Snapshots" as "name Snapshot 1.png"...
struct VideoSnapshotsTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var player: Kit.Player
    @State private var link = Kit.WindowLink()
    @State private var frames: [Snap] = []
    @State private var adding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let previewHeight: CGFloat

    fileprivate struct Snap: Identifiable {
        let id = UUID()
        /// The exact start of the frame.
        let time: Double
        let image: CGImage?
    }

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _player = State(initialValue: Kit.Player(url: session.url))
        previewHeight = Kit.previewHeight(372, rest: 290, anchor: session.anchor)
    }

    private var halfFrame: Double { player.frameDuration * 0.5 }

    /// The frame on screen is already in the strip.
    private var isCurrentAdded: Bool {
        let t = player.frameStart(player.time)
        return frames.contains { abs($0.time - t) < halfFrame }
    }

    private var saveTitle: String {
        switch frames.count {
        case 0: "Save Frames"
        case 1: "Save 1 Frame"
        default: "Save \(frames.count) Frames"
        }
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                Kit.PreviewBox(player: player, height: previewHeight) { _ in EmptyView() }
                Slider(value: scrub, in: 0...max(player.duration, 0.01))
                    .labelsHidden()
                    .disabled(!player.isReady)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 16)
                Kit.Transport(player: player, showsPlay: false)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 4)
                Divider()
                    .padding(.top, 12)
                HStack {
                    Text("\(frames.count) selected")
                        .font(Kit.Look.caption)
                        .foregroundStyle(ToolStyle.secondary)
                        .contentTransition(.numericText(value: Double(frames.count)))
                    Spacer()
                    Button("Add Frame", action: addFrame)
                        .disabled(!player.isReady || adding || isCurrentAdded)
                }
                .padding(.horizontal, Kit.Look.inset)
                .padding(.top, 12)
                strip
                    .padding(.top, 10)
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: saveTitle,
                       primaryEnabled: player.isReady && !frames.isEmpty, onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) { player.stop() })
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    private var scrub: Binding<Double> {
        Binding(get: { player.time }, set: { player.seek(to: $0) })
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(frames) { snap in
                        SnapThumb(snap: snap,
                                  onSelect: { player.pause(); player.seek(to: snap.time) },
                                  onRemove: { remove(snap.id) })
                            .id(snap.id)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    if frames.isEmpty {
                        emptySlot
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Kit.Look.inset)
            }
            .scrollIndicators(.never)
            .frame(height: 48)
            .onChange(of: frames.count) { old, new in
                guard new > old, let last = lastAdded else { return }
                withAnimation(Kit.Look.motion(reduceMotion)) { proxy.scrollTo(last, anchor: nil) }
            }
        }
        .padding(.horizontal, -Kit.Look.inset)
    }

    @State private var lastAdded: UUID?

    /// Dashed slot with a camera: click to add the frame on screen.
    private var emptySlot: some View {
        Button(action: addFrame) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(ToolStyle.secondary.opacity(0.7))
                .frame(width: 78, height: 48)
                .overlay {
                    Image(systemName: "camera")
                        .font(.system(size: 13))
                        .foregroundStyle(ToolStyle.secondary)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!player.isReady || adding)
        .help("Add Frame")
        .accessibilityLabel("Add Frame")
    }

    private func addFrame() {
        guard player.isReady, !adding, let asset = player.asset else { return }
        player.pause()
        let t = player.time
        let fallback = player.frameStart(t)
        adding = true
        Task {
            let still = await VideoToolKit.still(asset, at: t, maxSize: CGSize(width: 156, height: 96))
            adding = false
            // The frame's real start: exact even for variable frame rates.
            let time = still?.time ?? fallback
            guard !frames.contains(where: { abs($0.time - time) < halfFrame }) else { return }
            let snap = Snap(time: time, image: still?.image)
            lastAdded = snap.id
            withAnimation(Kit.Look.motion(reduceMotion)) {
                frames.append(snap)
                frames.sort { $0.time < $1.time }
            }
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(Kit.Look.motion(reduceMotion)) {
            frames.removeAll { $0.id == id }
        }
    }

    private func apply() {
        let src = session.url
        let times = frames.map(\.time).sorted()
        let fps = player.info.fps
        let viaFFmpeg = player.usesPreviewCopy
        let suffix = session.tool.outputSuffix
        let stem = Output.stem(src)
        player.stop()
        let step = JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
            if times.count == 1 {
                let out = ctx.output("\(stem) \(suffix).png")
                try VideoToolKit.snapshots(src, times: times, to: [out], fps: fps, viaFFmpeg: viaFFmpeg, ctx: ctx)
                return [out]
            }
            let folder = ctx.output("\(stem) \(suffix)s")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let outs = times.indices.map { folder.appendingPathComponent("\(stem) \(suffix) \($0 + 1).png") }
            try VideoToolKit.snapshots(src, times: times, to: outs, fps: fps, viaFFmpeg: viaFFmpeg, ctx: ctx)
            return [folder]
        }
        session.run([step])
    }
}

/// One chosen frame: the picture, its time, and a × to drop it.
private struct SnapThumb: View {
    let snap: VideoSnapshotsTool.Snap
    var onSelect: () -> Void
    var onRemove: () -> Void
    @State private var hoveringRemove = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color(white: 0.125)
                if let image = snap.image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 78, height: 48)
            .overlay(alignment: .bottomLeading) {
                Text(VideoToolKit.clock(snap.time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(.leading, 5)
                    .padding(.bottom, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .help("Show this frame")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(.black.opacity(hoveringRemove ? 1 : 0.8)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringRemove = $0 }
            .padding(.top, 7)
            .padding(.trailing, 7)
            .help("Remove")
            .accessibilityLabel("Remove frame at \(VideoToolKit.clock(snap.time))")
        }
    }
}
