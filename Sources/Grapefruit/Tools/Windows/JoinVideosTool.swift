import SwiftUI

private typealias Kit = VideoToolKit

/// Join Videos: put the clips in playback order (arrows or drag) and save one MP4,
/// "first name Joined.mp4", next to the first clip.
struct JoinVideosTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var clips: [JoinClip]
    @State private var link = Kit.WindowLink()
    @State private var dragged: UUID?
    @State private var dragFrom = 0
    @State private var dragTo = 0
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rowHeight: CGFloat = 40
    private static let spacing: CGFloat = 6
    private static var pitch: CGFloat { rowHeight + spacing }
    /// More rows than this scroll.
    private static let visibleRows = 6

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        let sorted = session.urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        _clips = State(initialValue: sorted.map { JoinClip(url: $0) })
    }

    private var total: Double? {
        var sum = 0.0
        for clip in clips {
            guard let d = clip.duration else { return nil }
            sum += d
        }
        return sum
    }

    private var unreadable: Bool { clips.contains { $0.failed } }

    var body: some View {
        ToolChrome(title: session.tool.name, width: 320, onClose: session.close) {
            VStack(spacing: 8) {
                HStack {
                    Text("Playback order")
                    Spacer()
                    if let total {
                        Text("\(Kit.clock(total)) total")
                            .monospacedDigit()
                            .transition(.opacity)
                    }
                }
                .font(Kit.Look.caption)
                .foregroundStyle(ToolStyle.secondary)
                .animation(.easeOut(duration: 0.2), value: total == nil)
                list
                if unreadable {
                    Text("Grapefruit can't read one of these videos.")
                        .font(Kit.Look.caption)
                        .foregroundStyle(ToolStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Join Videos",
                       primaryEnabled: clips.count >= 2 && !unreadable, onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) {})
        .task { await loadDetails() }
    }

    @ViewBuilder
    private var list: some View {
        let rows = VStack(spacing: Self.spacing) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                row(clip, index: index)
                    .offset(y: offset(for: index, clip: clip))
                    .zIndex(clip.id == dragged ? 1 : 0)
                    .gesture(reorder(clip, index: index))
            }
        }
        .modifier(Kit.OwnsDrags(link: link))
        if clips.count > Self.visibleRows {
            ScrollView(.vertical) { rows }
                .frame(height: CGFloat(Self.visibleRows) * Self.pitch - Self.spacing)
        } else {
            rows
                .frame(minHeight: 150, alignment: .top)
        }
    }

    private func row(_ clip: JoinClip, index: Int) -> some View {
        let isDragged = clip.id == dragged
        return HStack(spacing: 9) {
            Text("\(shownIndex(index, clip: clip) + 1)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(ToolStyle.secondary)
                .frame(minWidth: 12, alignment: .trailing)
            Poster(image: clip.image, failed: clip.failed)
            Text(clip.url.lastPathComponent)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(clip.url.lastPathComponent)
            Spacer(minLength: 4)
            Group {
                if clip.failed {
                    Text("Can't read")
                } else if let d = clip.duration {
                    Text(Kit.clock(d))
                }
            }
            .font(Kit.Look.clock)
            .foregroundStyle(ToolStyle.secondary)
            VStack(spacing: 2) {
                OrderButton(symbol: "chevron.up", help: "Move up") { move(index, by: -1) }
                    .disabled(index == 0)
                OrderButton(symbol: "chevron.down", help: "Move down") { move(index, by: 1) }
                    .disabled(index == clips.count - 1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isDragged ? 0.08 : 0.045))
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(isDragged ? 0.16 : 0), radius: 8, y: 3)
        )
        .scaleEffect(isDragged && !reduceMotion ? 1.02 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .pointerStyle(isDragged ? .grabActive : .grabIdle)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move up") { move(index, by: -1) }
        .accessibilityAction(named: "Move down") { move(index, by: 1) }
    }

    // MARK: Reordering

    /// The number a row shows while another row is dragged over it.
    private func shownIndex(_ index: Int, clip: JoinClip) -> Int {
        guard dragged != nil else { return index }
        if clip.id == dragged { return dragTo }
        if dragFrom < dragTo, index > dragFrom, index <= dragTo { return index - 1 }
        if dragTo < dragFrom, index >= dragTo, index < dragFrom { return index + 1 }
        return index
    }

    private func offset(for index: Int, clip: JoinClip) -> CGFloat {
        guard dragged != nil else { return 0 }
        if clip.id == dragged { return dragOffset }
        return CGFloat(shownIndex(index, clip: clip) - index) * Self.pitch
    }

    private func reorder(_ clip: JoinClip, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragged == nil {
                    dragged = clip.id
                    dragFrom = index
                    dragTo = index
                }
                guard dragged == clip.id else { return }
                dragOffset = value.translation.height
                let target = min(max(0, dragFrom + Int((dragOffset / Self.pitch).rounded())), clips.count - 1)
                if target != dragTo {
                    withAnimation(Kit.Look.motion(reduceMotion)) { dragTo = target }
                    Kit.haptic()
                }
            }
            .onEnded { _ in
                guard dragged == clip.id else { return }
                withAnimation(Kit.Look.motion(reduceMotion)) {
                    if dragTo != dragFrom {
                        clips.move(fromOffsets: IndexSet(integer: dragFrom), toOffset: dragTo > dragFrom ? dragTo + 1 : dragTo)
                    }
                    dragged = nil
                    dragOffset = 0
                }
            }
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard clips.indices.contains(index), clips.indices.contains(target) else { return }
        withAnimation(Kit.Look.motion(reduceMotion)) {
            clips.swapAt(index, target)
        }
    }

    // MARK: Loading and saving

    /// Lengths first (quick), then the small frames.
    private func loadDetails() async {
        for clip in clips {
            let url = clip.url
            let probe = await Task.detached(priority: .userInitiated) { try? VideoToolKit.probe(url) }.value
            if let probe, probe.hasVideo, probe.duration > 0 {
                clip.duration = probe.duration
            } else {
                clip.failed = true
            }
        }
        for clip in clips where !clip.failed {
            let url = clip.url
            let at = min(1, (clip.duration ?? 0) * 0.25)
            let image = await Task.detached(priority: .utility) {
                await VideoToolKit.poster(url, at: at, maxPixels: 96)
            }.value
            withAnimation(.easeOut(duration: 0.2)) { clip.image = image }
        }
    }

    private func apply() {
        let sources = clips.map(\.url)
        guard let first = sources.first else { return }
        let name = Output.name(first, suffix: session.tool.outputSuffix, ext: "mp4")
        let step = JobStep(name: "\(sources.count) videos", destination: first.deletingLastPathComponent()) { ctx in
            let out = ctx.output(name)
            try VideoToolKit.join(sources, to: out, ctx: ctx)
            return [out]
        }
        session.run([step])
    }
}

/// One clip in the list. Its length and frame arrive after the window opens.
@MainActor
@Observable
private final class JoinClip: Identifiable {
    let id = UUID()
    let url: URL
    var duration: Double?
    var image: CGImage?
    var failed = false

    init(url: URL) {
        self.url = url
    }
}

/// The clip's frame, fitted in a 32×28 slot; grey while it loads.
private struct Poster: View {
    let image: CGImage?
    let failed: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(VideoToolKit.Look.placeholder)
                    .overlay {
                        if failed {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(ToolStyle.secondary)
                        }
                    }
            }
        }
        .frame(width: 32, height: 28)
    }
}

/// The small up and down buttons stacked at the end of a row.
private struct OrderButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 32, height: 13)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isEnabled ? (hovering ? 0.12 : 0.07) : 0.035))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary.opacity(0.75) : Color.primary.opacity(0.25))
        .onHover { hovering = $0 }
        .help(help)
    }
}
