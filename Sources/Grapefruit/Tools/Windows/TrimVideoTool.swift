import SwiftUI

private typealias Kit = VideoToolKit

/// Trim Video: drag the orange handles to keep part of a clip. The kept range plays on a loop and
/// steps frame by frame. Saves "name Trimmed.ext", losslessly for MP4 and MOV.
struct TrimVideoTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var player: Kit.Player
    @State private var thumbs = Kit.Thumbnails()
    @State private var link = Kit.WindowLink()
    @State private var start = 0.0
    @State private var end = 0.0
    private let previewHeight: CGFloat

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _player = State(initialValue: Kit.Player(url: session.url))
        // The original's 380pt preview, smaller when the window wouldn't fit the screen.
        previewHeight = Kit.previewHeight(380, rest: 300, anchor: session.anchor)
    }

    /// At least one frame, and never more than the clip.
    private var minLength: Double {
        min(player.duration, max(player.frameDuration, 0.1))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                Kit.PreviewBox(player: player, height: previewHeight) { _ in EmptyView() }
                ToolCaption(text: "Drag the ends to trim",
                            value: player.isReady ? "\(Kit.clock(max(0, end - start))) selected" : nil)
                    .padding(.top, 16)
                Kit.TrimStrip(player: player, thumbs: thumbs, start: $start, end: $end, minLength: minLength)
                    .frame(height: 88)
                    .opacity(player.failure == nil ? 1 : 0.45)
                    .allowsHitTesting(player.isReady)
                    .modifier(Kit.OwnsDrags(link: link))
                    .padding(.top, 8)
                HStack {
                    Text("Start \(Kit.clock(start))")
                    Spacer()
                    Text("End \(Kit.clock(end))")
                }
                .font(Kit.Look.mono)
                .foregroundStyle(ToolStyle.secondary)
                .padding(.top, 6)
                Kit.Transport(player: player, range: start...max(start, end))
                    .padding(.top, 8)
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Apply", primaryEnabled: player.isReady && end > start,
                       onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) {
            player.stop()
            thumbs.cancel()
        })
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: player.duration) { _, duration in
            guard duration > 0, end == 0 else { return }
            end = duration
            player.loop = 0...duration
        }
        .onChange(of: start) { updateLoop() }
        .onChange(of: end) { updateLoop() }
    }

    private func updateLoop() {
        guard end > start else { return }
        player.loop = start...end
    }

    private func apply() {
        let a = start
        // The end handle at the last frame keeps everything to the end of the file.
        let b = end >= player.duration - player.frameDuration * 0.5 ? Double.infinity : end
        player.stop()
        session.runEach { src, out, ctx in
            try VideoToolKit.trim(src, start: a, end: b, to: out, ctx: ctx)
        }
    }
}
