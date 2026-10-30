import AppKit
import SwiftUI

/// Create Collage: two or more images on one canvas, previewed live and saved next to the first
/// image as "name Collage.jpg" (every input a JPEG and the result opaque) or "name Collage.png".
/// The preview and the saved file come from the same layout (MarkupKit.Collage.layout).
struct CollageTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: CollageModel
    @State private var section: CollageSection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: ToolSession) {
        self.session = session
        _model = StateObject(wrappedValue: CollageModel(urls: session.urls))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: CollageMetrics.windowWidth, onClose: session.close) {
            VStack(alignment: .leading, spacing: 0) {
                PreviewArea(model: model)
                if let note = model.failureNote {
                    FailureLine(note: note)
                        .padding(.top, 8)
                        .padding(.horizontal, CollageMetrics.inset)
                        .transition(.opacity)
                }
                Group {
                    SettingsForm(model: model)
                        .padding(.top, 17)
                        .padding(.horizontal, CollageMetrics.inset)
                    Divider()
                        .padding(.top, 12)
                        .padding(.horizontal, CollageMetrics.inset)
                    sections
                        .padding(.horizontal, CollageMetrics.inset)
                    HStack {
                        Spacer()
                        Button("Reset Layout") { model.resetLayout() }
                            .controlSize(.small)
                            .disabled(model.isDefault)
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, CollageMetrics.inset)
                }
                // Nothing to arrange with fewer than 2 images, so the settings rest.
                .disabled(model.cannotMake)
            }
            .animation(MarkupKit.spring(reduceMotion), value: section)
            .animation(MarkupKit.spring(reduceMotion), value: model.settings.style)
            .animation(MarkupKit.spring(reduceMotion), value: model.failureNote)
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Create Collage", primaryEnabled: model.canCreate, onPrimary: create)
        }
        .task { await model.load() }
    }

    /// One section open at a time, so the window never grows much.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkupKit.DisclosureHeader(title: "Spacing & background", isOpen: section == .spacing) { toggle(.spacing) }
                .padding(.top, 12)
            if section == .spacing {
                SpacingSection(model: model)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            MarkupKit.DisclosureHeader(title: "Image order", isOpen: section == .order) { toggle(.order) }
                .padding(.top, 11.5)
            if section == .order {
                OrderSection(model: model)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    private func toggle(_ s: CollageSection) {
        section = section == s ? nil : s
    }

    private func create() {
        guard let step = model.makeStep(suffix: session.tool.outputSuffix) else { return }
        session.run([step])
    }
}

private enum CollageSection: Hashable {
    case spacing, order
}

// MARK: - Layout

/// Sizes measured from the original window: 400 pt wide, a 294 pt preview, form rows inset a little more.
private enum CollageMetrics {
    static let windowWidth: CGFloat = 400
    static let inset: CGFloat = 6
    static let preview = CGSize(width: 376, height: 294)
    static var formWidth: CGFloat { windowWidth - 2 * ToolStyle.contentPadding - 2 * inset }

    /// Backgrounds that suit photos: white, warm paper, soft grey, graphite, black or none.
    static let backgrounds: [MarkupKit.Swatch] = [
        MarkupKit.Swatch(name: "White", color: MarkupKit.RGBA(0xFFFFFF)),
        MarkupKit.Swatch(name: "Paper", color: MarkupKit.RGBA(0xF3EFE6)),
        MarkupKit.Swatch(name: "Grey", color: MarkupKit.RGBA(0xE5E5EA)),
        MarkupKit.Swatch(name: "Graphite", color: MarkupKit.RGBA(0x2C2C2E)),
        MarkupKit.Swatch(name: "Black", color: MarkupKit.RGBA(0x000000)),
        MarkupKit.Swatch(name: "Transparent", color: nil),
    ]
}

// MARK: - Model

@MainActor
private final class CollageModel: ObservableObject {
    struct Item: Identifiable {
        /// The file's place in the original selection. Stays the same when the order changes.
        let id: Int
        let url: URL
        /// Width over height of the upright original. nil until it's known.
        var aspect: CGFloat?
        /// A downscaled copy for the preview and the order strip.
        var thumb: CGImage?
        var wideGamut = false
        var failed = false

        var name: String { url.lastPathComponent }
        var isLoading: Bool { thumb == nil && !failed }
    }

    /// What a background decode hands back.
    private struct Decoded: @unchecked Sendable {
        let id: Int
        let picture: MarkupKit.Picture?
    }

    @Published private(set) var items: [Item]
    @Published var settings: MarkupKit.CollageSettings
    let defaults: MarkupKit.CollageSettings
    private var started = false

    init(urls: [URL]) {
        items = urls.enumerated().map { Item(id: $0.offset, url: $0.element) }
        var s = MarkupKit.CollageSettings()
        s.columns = MarkupKit.CollageSettings.defaultColumns(for: urls.count)
        defaults = s
        settings = s
    }

    // MARK: Derived

    var usable: [Item] { items.filter { !$0.failed } }
    var isLoading: Bool { items.contains { $0.isLoading } }
    var canCreate: Bool { !isLoading && usable.count >= 2 }
    /// Loaded, and fewer than 2 images opened.
    var cannotMake: Bool { !isLoading && usable.count < 2 }
    var isDefault: Bool { settings == defaults && items.map(\.id) == Array(items.indices) }
    var order: [Int] { items.map(\.id) }

    var layout: MarkupKit.CollageLayout {
        MarkupKit.Collage.layout(aspects: usable.map { $0.aspect ?? 1 }, settings: settings)
    }

    var maxColumns: Int { max(1, min(usable.count, 10)) }
    var columnsShown: Int { min(max(1, settings.columns), maxColumns) }

    /// Spacing and corners are kept as fractions of the width; the sliders show output pixels.
    var spacingPixels: Double { Double(settings.spacing * CGFloat(settings.width)) }
    var cornerPixels: Double { Double(settings.corners * CGFloat(settings.width)) }
    var maxSpacingPixels: Double { (Double(settings.width) * 0.04).rounded() }
    var maxCornerPixels: Double { (Double(settings.width) * 0.08).rounded() }

    func setSpacing(pixels: Double) {
        let fraction = CGFloat(pixels.rounded()) / CGFloat(settings.width)
        settings.spacing = fraction
        // The edge margin follows the gaps, a little wider, as in the original.
        settings.margin = fraction * 1.5
    }

    func setCorners(pixels: Double) {
        settings.corners = CGFloat(pixels.rounded()) / CGFloat(settings.width)
    }

    var failureNote: FailureNote? {
        let failed = items.filter(\.failed)
        guard let first = failed.first else { return nil }
        return failed.count == 1 ? .one(first.name) : .many(failed.count)
    }

    // MARK: Loading

    func load() async {
        guard !started else { return }
        started = true
        let urls = items.map(\.url)
        // Shapes first: probing reads only headers, so the layout appears with grey cells right away.
        let sizes = await Task.detached(priority: .userInitiated) { urls.map { MarkupKit.probe($0) } }.value
        for (i, size) in sizes.enumerated() {
            if let size, let j = items.firstIndex(where: { $0.id == i }) {
                items[j].aspect = size.width / max(1, size.height)
            }
        }
        // Then the pixels, four at a time so twenty big photos don't swamp the Mac.
        await withTaskGroup(of: Decoded.self) { group in
            var next = 0
            while next < min(4, urls.count) {
                let id = next, url = urls[next]
                group.addTask(priority: .userInitiated) { Decoded(id: id, picture: try? MarkupKit.picture(url, maxPixel: 640)) }
                next += 1
            }
            for await decoded in group {
                apply(decoded)
                if next < urls.count {
                    let id = next, url = urls[next]
                    group.addTask(priority: .userInitiated) { Decoded(id: id, picture: try? MarkupKit.picture(url, maxPixel: 640)) }
                    next += 1
                }
            }
        }
    }

    private func apply(_ decoded: Decoded) {
        guard let i = items.firstIndex(where: { $0.id == decoded.id }) else { return }
        if let picture = decoded.picture {
            items[i].thumb = picture.image
            items[i].aspect = picture.aspect
            items[i].wideGamut = picture.isWideGamut
        } else {
            items[i].failed = true
        }
    }

    // MARK: Order

    func move(_ id: Int, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), items.count - 1)
        guard from != to else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    func move(_ id: Int, by step: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: from + step)
    }

    func swap(_ a: Int, _ b: Int) {
        guard a != b, let i = items.firstIndex(where: { $0.id == a }), let j = items.firstIndex(where: { $0.id == b }) else { return }
        items.swapAt(i, j)
    }

    func resetLayout() {
        settings = defaults
        items.sort { $0.id < $1.id }
    }

    // MARK: Export

    /// The job that renders and saves the collage, or nil when there's nothing to make yet.
    func makeStep(suffix: String) -> JobStep? {
        guard canCreate else { return nil }
        let chosen = usable
        let urls = chosen.map(\.url)
        let aspects = chosen.map { $0.aspect ?? 1 }
        let settings = self.settings
        let wideGamut = chosen.contains(where: \.wideGamut)
        // JPEG only when nothing is lost by it: every input is a JPEG and nothing is see-through.
        let allJPEG = urls.allSatisfy { Catalog.format(of: $0) == "jpg" }
        let format = allJPEG && settings.isOpaque ? "jpg" : "png"
        let first = urls[0]
        let name = Output.name(first, suffix: suffix, ext: format)
        return JobStep(name: name, destination: first.deletingLastPathComponent()) { ctx in
            let out = ctx.output(name)
            try MarkupKit.Collage.export(urls, aspects: aspects, settings: settings, wideGamut: wideGamut,
                                         format: format, to: out, job: ctx)
            return [out]
        }
    }
}

private enum FailureNote: Equatable {
    case one(String)
    case many(Int)
}

// MARK: - Preview

/// Where a dragged cell is and what it's over.
@MainActor
private final class SwapDrag: ObservableObject {
    @Published var source: Int?
    @Published var target: Int?
    @Published var point: CGPoint = .zero
}

/// One image placed in the preview: its slot in output pixels.
private struct PlacedCell: Identifiable {
    let item: CollageModel.Item
    let cell: MarkupKit.CollageCell
    var id: Int { item.id }
}

private struct PreviewArea: View {
    @ObservedObject var model: CollageModel
    @StateObject private var drag = SwapDrag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let box = CollageMetrics.preview
        ZStack {
            if model.cannotMake {
                emptyState
                    .transition(.opacity)
            } else {
                collage(in: box)
            }
        }
        .frame(width: box.width, height: box.height)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 26, weight: .light))
            Text(model.items.count < 2 ? "A collage needs at least 2 images." : "Not enough of these images could be opened.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(width: CollageMetrics.preview.width, height: CollageMetrics.preview.height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func collage(in box: CGSize) -> some View {
        let layout = model.layout
        let scale = min(box.width / max(1, layout.size.width), box.height / max(1, layout.size.height))
        let size = CGSize(width: (layout.size.width * scale).rounded(), height: (layout.size.height * scale).rounded())
        let placed = zip(model.usable, layout.cells).map { PlacedCell(item: $0.0, cell: $0.1) }
        return ZStack(alignment: .topLeading) {
            backdrop
                .frame(width: size.width, height: size.height)
            ForEach(placed) { p in
                PreviewCell(item: p.item, cell: p.cell, scale: scale,
                            dimmed: drag.source == p.id, targeted: drag.target == p.id && drag.source != p.id)
            }
            if let source = drag.source, let p = placed.first(where: { $0.id == source }) {
                ghost(p, scale: scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .overlay {
            DragSurface(
                canDrag: { point in model.usable.count >= 2 && Self.hit(point, placed: placed, scale: scale) != nil },
                began: { point in
                    drag.source = Self.hit(point, placed: placed, scale: scale)
                    drag.point = point
                },
                moved: { point in
                    drag.point = point
                    let over = Self.hit(point, placed: placed, scale: scale)
                    drag.target = over == drag.source ? nil : over
                },
                ended: {
                    let source = drag.source, target = drag.target
                    drag.source = nil
                    drag.target = nil
                    if let source, let target {
                        withAnimation(MarkupKit.spring(reduceMotion)) { model.swap(source, target) }
                    }
                }
            )
            .accessibilityHidden(true)
        }
        .animation(MarkupKit.spring(reduceMotion), value: model.settings)
        .animation(MarkupKit.spring(reduceMotion), value: model.order)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: drag.target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collage preview, \(placed.count) images")
    }

    @ViewBuilder private var backdrop: some View {
        if let background = model.settings.background {
            Rectangle().fill(background.color)
        } else {
            MarkupKit.Checkerboard(square: 6)
        }
    }

    /// A small copy of the dragged image riding under the pointer.
    private func ghost(_ p: PlacedCell, scale: CGFloat) -> some View {
        let clip = p.cell.clip
        let fitted = MarkupKit.fit(clip.size, in: CGRect(x: 0, y: 0, width: 84, height: 84), maxScale: scale)
        return Group {
            if let thumb = p.item.thumb {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.gray.opacity(0.4))
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .offset(x: drag.point.x - fitted.width / 2, y: drag.point.y - fitted.height / 2)
        .transition(.opacity)
    }

    /// The image under `point` (preview points). Empty grid slots and gutters don't count.
    private static func hit(_ point: CGPoint, placed: [PlacedCell], scale: CGFloat) -> Int? {
        placed.first { p in
            let f = p.cell.frame
            return CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale).contains(point)
        }?.id
    }
}

private struct PreviewCell: View {
    let item: CollageModel.Item
    let cell: MarkupKit.CollageCell
    let scale: CGFloat
    let dimmed: Bool
    let targeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clip = scaled(cell.clip)
        let image = scaled(cell.image)
        let shape = RoundedRectangle(cornerRadius: cell.radius * scale, style: .continuous)
        ZStack(alignment: .topLeading) {
            if let thumb = item.thumb {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: image.width, height: image.height)
                    .offset(x: image.minX - clip.minX, y: image.minY - clip.minY)
                    .transition(.opacity)
            } else {
                LoadingCell()
                    .frame(width: clip.width, height: clip.height)
                    .transition(.opacity)
            }
        }
        .frame(width: clip.width, height: clip.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ToolStyle.orange, lineWidth: 2).opacity(targeted ? 1 : 0))
        .opacity(dimmed ? 0.35 : 1)
        .offset(x: clip.minX, y: clip.minY)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: item.thumb == nil)
    }

    private func scaled(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
}

/// A grey cell that breathes while its image decodes. Still when Reduce Motion is on.
/// Driven by a timeline rather than a repeating animation, so it can't leak into the cells' layout springs.
private struct LoadingCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0 : (sin(t * 2 * .pi / 1.6) + 1) / 2
            Rectangle().fill(Color.primary.opacity(0.07 + 0.06 * phase))
        }
    }
}

private struct FailureLine: View {
    let note: FailureNote

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ToolStyle.orange)
                .padding(.trailing, 5)
            switch note {
            case .one(let name):
                // Two pieces so a long name shortens in the middle while the sentence stays whole.
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
                Text(" couldn't be opened, so it's left out.")
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            case .many(let count):
                Text("\(count) images couldn't be opened, so they're left out.")
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(height: 14)
    }
}

// MARK: - Form

private struct SettingsForm: View {
    @ObservedObject var model: CollageModel
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 12.5) {
            MarkupKit.FormRow(title: "Style") {
                Picker("Style", selection: $model.settings.style) {
                    ForEach(MarkupKit.CollageStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if model.settings.style == .grid {
                MarkupKit.FormRow(title: "Columns") {
                    HStack(spacing: 6) {
                        Text("\(model.columnsShown)")
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(isEnabled ? .primary : .tertiary)
                            .contentTransition(.numericText())
                        Stepper("Columns", value: Binding(get: { model.columnsShown }, set: { model.settings.columns = $0 }),
                                in: 1...model.maxColumns)
                            .labelsHidden()
                    }
                }
                .transition(.opacity)
            }
            MarkupKit.FormRow(title: "Canvas") {
                Picker("Canvas", selection: $model.settings.canvas) {
                    ForEach(MarkupKit.CollageCanvas.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            MarkupKit.FormRow(title: "Width") {
                Picker("Width", selection: $model.settings.width) {
                    ForEach(MarkupKit.CollageSettings.widths, id: \.self) { Text("\($0.formatted()) px").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            MarkupKit.FormRow(title: "Image fit") {
                Picker("Image fit", selection: $model.settings.fill) {
                    Text("Fill cells (crop edges)").tag(true)
                    Text("Fit whole images").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
        .controlSize(.small)
    }
}

private struct SpacingSection: View {
    @ObservedObject var model: CollageModel

    var body: some View {
        VStack(spacing: 12.5) {
            SliderRow(title: "Spacing",
                      value: Binding(get: { model.spacingPixels }, set: { model.setSpacing(pixels: $0) }),
                      range: 0...model.maxSpacingPixels)
            SliderRow(title: "Corners",
                      value: Binding(get: { model.cornerPixels }, set: { model.setCorners(pixels: $0) }),
                      range: 0...model.maxCornerPixels)
            MarkupKit.FormRow(title: "Background") {
                HStack(spacing: 1) {
                    ForEach(CollageMetrics.backgrounds) { swatch in
                        MarkupKit.SwatchChip(swatch: swatch, selected: swatch.color == model.settings.background, diameter: 14) {
                            model.settings.background = swatch.color
                        }
                    }
                }
            }
        }
        .controlSize(.small)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        MarkupKit.FormRow(title: title) {
            Slider(value: $value, in: range)
                .frame(width: 168)
            Text("\(Int(value.rounded())) px")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Order strip

/// The dragged thumbnail: which one, where its corner is, and where it was grabbed.
@MainActor
private final class StripDrag: ObservableObject {
    @Published var id: Int?
    @Published var origin: CGPoint = .zero
    var grab = CGSize.zero
}

private enum Strip {
    static let thumb: CGFloat = 44
    static let gap: CGFloat = 6
    static let corner: CGFloat = 7
    /// Rows shown before the strip scrolls.
    static let visibleRows = 3

    static func columns(_ width: CGFloat) -> Int { max(1, Int((width + gap) / (thumb + gap))) }
    static func rows(_ count: Int, columns: Int) -> Int { max(1, (count + columns - 1) / columns) }

    static func origin(_ slot: Int, columns: Int) -> CGPoint {
        CGPoint(x: CGFloat(slot % columns) * (thumb + gap), y: CGFloat(slot / columns) * (thumb + gap))
    }

    static func height(rows: Int) -> CGFloat { CGFloat(rows) * thumb + CGFloat(rows - 1) * gap }

    /// The slot whose cell is nearest `p`.
    static func slot(nearest p: CGPoint, columns: Int, count: Int) -> Int {
        let col = min(max(Int(floor(p.x / (thumb + gap))), 0), columns - 1)
        let row = max(Int(floor(p.y / (thumb + gap))), 0)
        return min(max(row * columns + col, 0), max(0, count - 1))
    }

    /// The slot right under `p`, or nil in a gap.
    static func slot(at p: CGPoint, columns: Int, count: Int) -> Int? {
        let s = slot(nearest: p, columns: columns, count: count)
        let o = origin(s, columns: columns)
        return CGRect(origin: o, size: CGSize(width: thumb, height: thumb)).contains(p) ? s : nil
    }
}

private struct OrderSection: View {
    @ObservedObject var model: CollageModel
    @StateObject private var drag = StripDrag()
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = CollageMetrics.formWidth
        let columns = Strip.columns(width)
        let rows = Strip.rows(model.items.count, columns: columns)
        VStack(alignment: .leading, spacing: 7) {
            if rows > Strip.visibleRows {
                ScrollView(.vertical) {
                    strip(width: width, columns: columns, rows: rows)
                }
                .frame(height: Strip.height(rows: Strip.visibleRows) + Strip.gap)
            } else {
                strip(width: width, columns: columns, rows: rows)
            }
            caption
        }
    }

    private var caption: some View {
        let name = hovered.flatMap { id in model.items.first { $0.id == id } }.map(\.name)
        return Text(name ?? "Drag the thumbnails to change the order.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 13)
    }

    private func strip(width: CGFloat, columns: Int, rows: Int) -> some View {
        let count = model.items.count
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let lifted = drag.id == item.id
                let origin = lifted ? drag.origin : Strip.origin(index, columns: columns)
                ThumbTile(item: item, lifted: lifted)
                    .offset(x: origin.x, y: origin.y)
                    .zIndex(lifted ? 1 : 0)
                    .animation(lifted || reduceMotion ? nil : MarkupKit.spring(false), value: origin)
                    .accessibilityAction(named: "Move earlier") { withAnimation(MarkupKit.spring(reduceMotion)) { model.move(item.id, by: -1) } }
                    .accessibilityAction(named: "Move later") { withAnimation(MarkupKit.spring(reduceMotion)) { model.move(item.id, by: 1) } }
            }
        }
        .frame(width: width, height: Strip.height(rows: rows), alignment: .topLeading)
        .overlay {
            DragSurface(
                canDrag: { point in Strip.slot(at: point, columns: columns, count: count) != nil && count > 1 },
                began: { point in
                    guard let slot = Strip.slot(at: point, columns: columns, count: model.items.count),
                          slot < model.items.count else { return }
                    let origin = Strip.origin(slot, columns: columns)
                    drag.id = model.items[slot].id
                    drag.origin = origin
                    drag.grab = CGSize(width: point.x - origin.x, height: point.y - origin.y)
                },
                moved: { point in
                    guard let id = drag.id else { return }
                    let maxX = width - Strip.thumb, maxY = Strip.height(rows: rows) - Strip.thumb
                    let origin = CGPoint(x: min(max(point.x - drag.grab.width, -6), maxX + 6),
                                         y: min(max(point.y - drag.grab.height, -6), maxY + 6))
                    drag.origin = origin
                    let center = CGPoint(x: origin.x + Strip.thumb / 2, y: origin.y + Strip.thumb / 2)
                    let target = Strip.slot(nearest: center, columns: columns, count: model.items.count)
                    if model.items.firstIndex(where: { $0.id == id }) != target {
                        withAnimation(MarkupKit.spring(reduceMotion)) { model.move(id, to: target) }
                    }
                },
                ended: {
                    withAnimation(MarkupKit.spring(reduceMotion)) { drag.id = nil }
                },
                hover: { point in
                    let slot = point.flatMap { Strip.slot(at: $0, columns: columns, count: model.items.count) }
                    hovered = slot.flatMap { $0 < model.items.count ? model.items[$0].id : nil }
                }
            )
            .accessibilityHidden(true)
        }
    }
}

private struct ThumbTile: View {
    let item: CollageModel.Item
    let lifted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Strip.corner, style: .continuous)
        ZStack {
            if let thumb = item.thumb {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else if item.failed {
                Rectangle().fill(Color.primary.opacity(0.05))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ToolStyle.orange)
            } else {
                LoadingCell()
            }
        }
        .frame(width: Strip.thumb, height: Strip.thumb)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .scaleEffect(lifted ? 1.08 : 1)
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 8 : 0, y: lifted ? 3 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: lifted)
        .accessibilityElement()
        .accessibilityLabel(item.failed ? "\(item.name), couldn't be opened" : item.name)
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Dragging

/// An invisible AppKit layer over the preview and the strip. The tool window moves when you drag
/// its background, so drags here need a view that tells AppKit not to move the window.
private struct DragSurface: NSViewRepresentable {
    var canDrag: (CGPoint) -> Bool
    var began: (CGPoint) -> Void
    var moved: (CGPoint) -> Void
    var ended: () -> Void
    var hover: (CGPoint?) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSurfaceView {
        let view = DragSurfaceView()
        view.surface = self
        return view
    }

    func updateNSView(_ view: DragSurfaceView, context: Context) {
        view.surface = self
    }
}

private final class DragSurfaceView: NSView {
    var surface: DragSurface?
    private var tracking: NSTrackingArea?
    private var start: CGPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        start = surface?.canDrag(p) == true ? p : nil
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let surface else { return }
        let p = point(event)
        if !dragging {
            // A few points of travel before it counts, so clicks stay clicks.
            guard hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
            dragging = true
            surface.began(start)
            NSCursor.closedHand.set()
        }
        surface.moved(p)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { surface?.ended() }
        start = nil
        dragging = false
        updateCursor(point(event))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        updateCursor(p)
        surface?.hover(p)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(point(event))
    }

    override func mouseExited(with event: NSEvent) {
        surface?.hover(nil)
        if !dragging { NSCursor.arrow.set() }
    }

    private func updateCursor(_ p: CGPoint) {
        guard !dragging else { return }
        (surface?.canDrag(p) == true ? NSCursor.openHand : NSCursor.arrow).set()
    }
}
