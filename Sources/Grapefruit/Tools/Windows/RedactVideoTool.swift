import AppKit
import SwiftUI

private typealias Kit = VideoToolKit

/// Redact Video: draw boxes over what should be hidden, choose when each one shows, and save
/// "name Redacted.ext" with the boxes burned in as a solid color or a heavy blur.
struct RedactVideoTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var player: Kit.Player
    @State private var thumbs = Kit.Thumbnails()
    @State private var link = Kit.WindowLink()
    @State private var boxes: [RedactBox] = []
    @State private var selected: UUID?
    @State private var style = Style.solid
    @State private var color = Color.black
    /// The box being drawn on the picture.
    @State private var drawing: UUID?
    /// Where a box sat when a move on the picture started.
    @State private var moveOrigin: CGRect?
    /// A box's times when a drag on its row started.
    @State private var rangeOrigin: (start: Double, end: Double)?
    /// The range being dragged out on the "Drag to add" row.
    @State private var draft: ClosedRange<Double>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let previewHeight: CGFloat

    enum Style: String, CaseIterable {
        case solid = "Solid"
        case blur = "Blur"
    }

    private static let rowHeight: CGFloat = 26
    private static let rowSpacing: CGFloat = 5
    private static let numberColumn: CGFloat = 28

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _player = State(initialValue: Kit.Player(url: session.url))
        previewHeight = Kit.previewHeight(521, rest: 415, anchor: session.anchor)
    }

    /// The shortest time a box can cover.
    private var minimumRange: Double { min(player.duration, max(player.frameDuration, 0.1)) }

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            VStack(spacing: 0) {
                Kit.PreviewBox(player: player, height: previewHeight) { video in
                    picture(video)
                }
                styleRows
                Divider()
                    .padding(.top, 12)
                Text("Redactions")
                    .font(ToolStyle.sectionTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 12)
                rangeList
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 8)
                filmRow
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 8)
                Kit.Transport(player: player)
                    .padding(.horizontal, Kit.Look.inset)
                    .padding(.top, 8)
            }
            .background { deleteShortcut }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Save Redacted Copy",
                       primaryEnabled: player.isReady && !boxes.isEmpty, onPrimary: apply)
        }
        .background(Kit.WindowHook(link: link) {
            player.stop()
            thumbs.cancel()
        })
        .onAppear { player.start() }
        .onDisappear { player.stop() }
    }

    // MARK: Picture

    /// Boxes on the video: drag empty space to draw one, drag a box to move it, handles resize.
    private func picture(_ video: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: video.width, height: video.height)
                .contentShape(Rectangle())
                .pointerStyle(.rectSelection)
                .gesture(draw(in: video))
                .position(x: video.midX, y: video.midY)
            ForEach(boxes) { box in
                if box.id == selected || isActive(box) {
                    cover(box, in: video)
                }
            }
            if let box = boxes.first(where: { $0.id == selected }) {
                Kit.RectEditor(rect: place(box.rect, in: video), bounds: video,
                               minSize: CGSize(width: 8, height: 8), space: "redact") { r in
                    update(box.id) { $0.rect = unplace(r, in: video) }
                }
            }
        }
        .coordinateSpace(.named("redact"))
        .modifier(Kit.OwnsDrags(link: link))
    }

    private func cover(_ box: RedactBox, in video: CGRect) -> some View {
        let r = place(box.rect, in: video)
        return coverFill
            .frame(width: max(1, r.width), height: max(1, r.height))
            .opacity(isActive(box) ? 1 : 0.45)
            .contentShape(Rectangle())
            .pointerStyle(.grabIdle)
            .gesture(moveBox(box, in: video))
            .contextMenu { Button("Delete") { delete(box.id) } }
            .position(x: r.midX, y: r.midY)
    }

    /// What the saved video will show: the chosen color, or a frosted blur.
    @ViewBuilder
    private var coverFill: some View {
        switch style {
        case .solid:
            Rectangle().fill(color)
        case .blur:
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private func draw(in video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("redact"))
            .onChanged { value in
                let a = clamp(value.startLocation, to: video)
                let b = clamp(value.location, to: video)
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                if let id = drawing {
                    update(id) { $0.rect = unplace(rect, in: video) }
                } else if hypot(value.translation.width, value.translation.height) >= 4 {
                    player.pause()
                    let box = RedactBox(rect: unplace(rect, in: video), start: 0, end: player.duration)
                    boxes.append(box)
                    drawing = box.id
                    selected = box.id
                }
            }
            .onEnded { _ in
                guard let id = drawing else {
                    // A click on the picture lets go of the selection.
                    withAnimation(.easeOut(duration: 0.15)) { selected = nil }
                    return
                }
                drawing = nil
                if let box = boxes.first(where: { $0.id == id }),
                   box.rect.width * video.width < 6 || box.rect.height * video.height < 6 {
                    delete(id)
                }
            }
    }

    private func moveBox(_ box: RedactBox, in video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("redact"))
            .onChanged { value in
                if moveOrigin == nil {
                    moveOrigin = place(box.rect, in: video)
                    select(box.id)
                }
                guard let origin = moveOrigin else { return }
                let moved = Kit.move(origin, by: value.translation, within: video)
                update(box.id) { $0.rect = unplace(moved, in: video) }
            }
            .onEnded { _ in moveOrigin = nil }
    }

    // MARK: Style

    private var styleRows: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Style")
                    .font(Kit.Look.caption)
                    .foregroundStyle(ToolStyle.secondary)
                Spacer()
                Picker("Style", selection: $style) {
                    ForEach(Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Color")
                    .font(Kit.Look.caption)
                    .foregroundStyle(ToolStyle.secondary)
                Spacer()
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(style == .blur)
            }
        }
        .padding(.horizontal, Kit.Look.inset)
        .padding(.top, 12)
    }

    // MARK: Ranges

    /// One row per box with the time it covers, then a row to add another.
    private var rangeList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(boxes.enumerated()), id: \.element.id) { index, box in
                        rangeRow(box, number: index + 1)
                            .id(box.id)
                    }
                    addRow
                }
                .overlay(alignment: .topLeading) { rowsPlayhead }
            }
            .frame(height: Self.rowHeight * 3 + Self.rowSpacing * 2)
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(Kit.Look.motion(reduceMotion)) { proxy.scrollTo(id) }
            }
        }
        .modifier(Kit.OwnsDrags(link: link))
        .disabled(!player.isReady)
    }

    private func rangeRow(_ box: RedactBox, number: Int) -> some View {
        let isSelected = box.id == selected
        return HStack(spacing: 0) {
            Text("\(number)")
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? Kit.Look.orange : ToolStyle.secondary)
                .frame(width: Self.numberColumn, alignment: .leading)
            GeometryReader { geo in
                rangeTrack(box, number: number, isSelected: isSelected, width: geo.size.width)
            }
            .frame(height: Self.rowHeight)
        }
        .contextMenu { Button("Delete") { delete(box.id) } }
    }

    private func rangeTrack(_ box: RedactBox, number: Int, isSelected: Bool, width: CGFloat) -> some View {
        let length = max(player.duration, 0.001)
        let x0 = CGFloat(min(max(box.start / length, 0), 1)) * width
        let x1 = CGFloat(min(max(box.end / length, 0), 1)) * width
        let barWidth = min(width, max(x1 - x0, 24))
        let barX = min(x0, width - barWidth)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Kit.Look.track)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Kit.Look.orange.opacity(isSelected ? 1 : 0.45))
                .overlay {
                    if barWidth >= 64 { barLabel(number) }
                }
                .frame(width: barWidth)
                .contentShape(Rectangle())
                .pointerStyle(.grabIdle)
                .gesture(rangeDrag(box, edge: nil, width: width))
                .overlay(alignment: .leading) { grip(box, edge: .start, width: width) }
                .overlay(alignment: .trailing) { grip(box, edge: .end, width: width) }
                .offset(x: barX)
        }
        .accessibilityElement()
        .accessibilityLabel("Box \(number)")
        .accessibilityValue("\(Kit.clock(box.start)) to \(Kit.clock(box.end))")
    }

    /// The white tick near each end of a range: drag to change when the box starts or stops.
    private func grip(_ box: RedactBox, edge: RangeEdge, width: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: 2, height: 14)
            .frame(width: 12, height: Self.rowHeight)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(rangeDrag(box, edge: edge, width: width))
    }

    /// Color dot and "Box N", centered in the range.
    private func barLabel(_ number: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(style == .solid ? color : Color.white.opacity(0.55))
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                .frame(width: 8, height: 8)
            Text("Box \(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .allowsHitTesting(false)
    }

    private func rangeDrag(_ box: RedactBox, edge: RangeEdge?, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let length = player.duration
                guard length > 0, width > 0 else { return }
                if rangeOrigin == nil {
                    rangeOrigin = (box.start, box.end)
                    if selected != box.id { selected = box.id }
                    player.pause()
                }
                guard let origin = rangeOrigin, abs(value.translation.width) > 0.5 else { return }
                let dt = Double(value.translation.width / width) * length
                var start = origin.start
                var end = origin.end
                switch edge {
                case .start?:
                    start = min(max(0, origin.start + dt), origin.end - minimumRange)
                case .end?:
                    end = max(min(length, origin.end + dt), origin.start + minimumRange)
                case nil:
                    let span = origin.end - origin.start
                    start = min(max(0, origin.start + dt), length - span)
                    end = start + span
                }
                update(box.id) {
                    $0.start = start
                    $0.end = end
                }
                // Show the frame at the edge being set.
                player.seek(to: edge == .end ? max(start, end - player.frameDuration * 0.5) : start)
            }
            .onEnded { value in
                rangeOrigin = nil
                if abs(value.translation.width) < 2, abs(value.translation.height) < 2 { select(box.id) }
            }
    }

    /// Drag across it to add a box for that stretch of time; click to add one for the whole video.
    private var addRow: some View {
        HStack(spacing: 0) {
            Text("\(boxes.count + 1)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(ToolStyle.secondary.opacity(0.6))
                .frame(width: Self.numberColumn, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Kit.Look.track)
                    if let draft {
                        let length = max(player.duration, 0.001)
                        let x0 = CGFloat(draft.lowerBound / length) * width
                        let x1 = CGFloat(draft.upperBound / length) * width
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Kit.Look.orange.opacity(0.45))
                            .frame(width: max(2, x1 - x0))
                            .offset(x: x0)
                    } else {
                        Text("Drag to add")
                            .font(.system(size: 11))
                            .foregroundStyle(ToolStyle.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(addDrag(width: width))
                .help("Drag to add a box for part of the video. Click to cover all of it.")
            }
            .frame(height: Self.rowHeight)
        }
    }

    private func addDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard player.isReady, width > 0 else { return }
                guard abs(value.translation.width) >= 3 || draft != nil else { return }
                let length = player.duration
                let a = Double(min(max(value.startLocation.x / width, 0), 1)) * length
                let b = Double(min(max(value.location.x / width, 0), 1)) * length
                draft = min(a, b)...max(a, b)
                player.pause()
                player.seek(to: b)
            }
            .onEnded { _ in
                guard player.isReady else { return }
                let length = player.duration
                var range = draft ?? 0...length
                draft = nil
                if range.upperBound - range.lowerBound < minimumRange {
                    let start = min(range.lowerBound, length - minimumRange)
                    range = start...(start + minimumRange)
                }
                addBox(start: range.lowerBound, end: range.upperBound)
            }
    }

    /// The 1pt playhead across the rows.
    private var rowsPlayhead: some View {
        GeometryReader { geo in
            let width = geo.size.width - Self.numberColumn
            let fraction = min(max(player.time / max(player.duration, 0.001), 0), 1)
            Rectangle()
                .fill(Color.primary.opacity(0.7))
                .frame(width: 1, height: geo.size.height)
                .offset(x: Self.numberColumn + CGFloat(fraction) * width - 0.5)
                .opacity(player.isReady ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    /// Frames of the whole video; drag along it to scrub.
    private var filmRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "film")
                .font(.system(size: 12))
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: Self.numberColumn, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                let length = max(player.duration, 0.001)
                ZStack(alignment: .topLeading) {
                    Kit.Filmstrip(player: player, thumbs: thumbs)
                        .clipShape(RoundedRectangle(cornerRadius: Kit.Look.stripCorner, style: .continuous))
                    if player.isReady {
                        Kit.PlayheadLine(height: geo.size.height)
                            .offset(x: CGFloat(min(max(player.time / length, 0), 1)) * width - 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            player.pause()
                            player.seek(to: Double(min(max(value.location.x / width, 0), 1)) * length)
                        }
                )
            }
            .frame(height: 54)
            .modifier(Kit.OwnsDrags(link: link))
        }
        .opacity(player.failure == nil ? 1 : 0.45)
        .allowsHitTesting(player.isReady)
    }

    /// Delete removes the selected box.
    private var deleteShortcut: some View {
        Button("Delete Box") {
            if let selected { delete(selected) }
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(selected == nil)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Model

    private func isActive(_ box: RedactBox) -> Bool {
        player.time >= box.start - 0.001 && player.time <= box.end + 0.001
    }

    /// Selects a box and shows a frame it covers.
    private func select(_ id: UUID) {
        selected = id
        guard let box = boxes.first(where: { $0.id == id }), !isActive(box) else { return }
        player.pause()
        player.seek(to: box.start)
    }

    private func addBox(start: Double, end: Double) {
        let size = player.displaySize
        // A square a third of the picture's short side, in the middle.
        let side = min(size.width, size.height) / 3
        let w = side / size.width
        let h = side / size.height
        let box = RedactBox(rect: CGRect(x: 0.5 - w / 2, y: 0.5 - h / 2, width: w, height: h), start: start, end: end)
        withAnimation(Kit.Look.motion(reduceMotion)) {
            boxes.append(box)
        }
        select(box.id)
    }

    private func delete(_ id: UUID) {
        withAnimation(Kit.Look.motion(reduceMotion)) {
            boxes.removeAll { $0.id == id }
            if selected == id { selected = nil }
        }
    }

    private func update(_ id: UUID, _ change: (inout RedactBox) -> Void) {
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        change(&boxes[i])
    }

    private func place(_ r: CGRect, in video: CGRect) -> CGRect {
        CGRect(x: video.minX + r.minX * video.width, y: video.minY + r.minY * video.height,
               width: r.width * video.width, height: r.height * video.height)
    }

    private func unplace(_ r: CGRect, in video: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return .zero }
        return CGRect(x: (r.minX - video.minX) / video.width, y: (r.minY - video.minY) / video.height,
                      width: r.width / video.width, height: r.height / video.height)
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func apply() {
        let duration = player.duration
        let tail = player.frameDuration * 0.5
        // Boxes that reach either end of the video cover it to the very first and last frame.
        let list = boxes.map { box in
            VideoToolKit.Redaction(rect: box.rect, start: box.start <= 0.001 ? 0 : box.start,
                                   end: box.end >= duration - tail ? .infinity : box.end)
        }
        let redactStyle: VideoToolKit.RedactStyle
        switch style {
        case .blur:
            redactStyle = .blur
        case .solid:
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            redactStyle = .solid(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        player.stop()
        session.runEach { src, out, ctx in
            try VideoToolKit.redact(src, boxes: list, style: redactStyle, to: out, ctx: ctx)
        }
    }
}

/// A box over the picture, in fractions of the picture, and the time it covers.
private struct RedactBox: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect
    var start: Double
    var end: Double
}

private enum RangeEdge {
    case start, end
}
