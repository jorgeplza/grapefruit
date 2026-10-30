import AppKit
import SwiftUI

/// Merge PDFs: the selected files in Finder's order, reordered with the arrows or by dragging,
/// then one PDF named after the first file, with a bookmark for each file.
/// Layout measured from the original window: 320pt wide, 284 × 41pt rows 5pt apart.
struct MergePDFTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var model: MergeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: ToolSession) {
        self.session = session
        _model = State(initialValue: MergeModel(urls: session.urls))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: 320, onClose: session.close) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Document order")
                    Spacer(minLength: 8)
                    if let total = model.totalPages {
                        Text(PDFToolKit.pageCount(total))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(total)))
                            .transition(.opacity)
                    }
                }
                .font(PDFToolKit.Look.text)
                .foregroundStyle(ToolStyle.secondary)
                .padding(.top, 4)

                MergeList(model: model)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 6)
        } footer: {
            if let note = model.blockedReason {
                Text(note)
                    .font(PDFToolKit.Look.text)
                    .foregroundStyle(ToolStyle.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            ToolFooter(showsReset: false, primaryTitle: "Merge PDFs",
                       primaryEnabled: model.canMerge, onPrimary: merge)
        }
        .background(PDFToolKit.WindowReader { model.attach($0) })
        .task { await model.load() }
        .onChange(of: reduceMotion, initial: true) { _, reduce in model.reduceMotion = reduce }
    }

    /// "first Merged.pdf" next to the first file in the chosen order.
    private func merge() {
        guard model.canMerge else { return }
        let urls = model.items.map(\.url)
        guard let first = urls.first else { return }
        let name = Output.name(first, suffix: session.tool.outputSuffix, ext: "pdf")
        model.close()
        session.run([
            JobStep(name: "\(urls.count) PDFs", destination: first.deletingLastPathComponent()) { ctx in
                let out = ctx.output(name)
                try PDFToolKit.merge(urls, to: out, ctx: ctx)
                return [out]
            }
        ])
    }
}

// MARK: - Model

@MainActor
@Observable
private final class MergeModel {
    struct Item: Identifiable {
        let id: Int
        let url: URL
        let reader: PDFToolKit.Reader
        var state: ItemState = .loading
    }

    enum ItemState: Equatable {
        case loading
        case ready(pages: Int, first: PDFToolKit.PageInfo)
        case failed(PDFToolKit.Problem)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    static let rows = PDFToolKit.GridMetrics(columns: 1, cell: CGSize(width: 284, height: 41),
                                             spacing: CGSize(width: 0, height: 5))
    /// Up to five rows show at once; more scroll, with the sixth peeking out.
    static let shortest: CGFloat = 149
    static let tallest: CGFloat = 250
    static let space = "merge.rows"

    var items: [Item]
    /// The row picked up by a drag. Its slot shows as an empty well while a lifted copy follows the pointer.
    var liftedID: Int?
    var liftY: CGFloat = 0
    var settling = false
    var scrollPosition = ScrollPosition(edge: .top)
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var scroll = PDFToolKit.ScrollMetrics()
    @ObservationIgnored let link = PDFToolKit.WindowLink()
    @ObservationIgnored private let autoScroller = PDFToolKit.AutoScroller()
    @ObservationIgnored private var grab: CGFloat = 0
    @ObservationIgnored private var pointerY: CGFloat = 0
    @ObservationIgnored private var ignoringGesture = false

    init(urls: [URL]) {
        items = urls.enumerated().map {
            Item(id: $0.offset, url: $0.element, reader: PDFToolKit.Reader(url: $0.element, cacheLimit: 2 << 20))
        }
    }

    func attach(_ window: NSWindow) {
        guard link.window !== window else { return }
        link.attach(window)
        link.whenClosed { [weak self] in self?.autoScroller.stop() }
    }

    func close() {
        autoScroller.stop()
        link.detach()
    }

    /// Page counts and first pages, all files at once.
    func load() async {
        await withTaskGroup(of: (Int, PDFToolKit.Contents).self) { group in
            for item in items {
                let id = item.id, reader = item.reader
                group.addTask { (id, await reader.contents()) }
            }
            for await (id, contents) in group {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                let state: ItemState
                switch contents {
                case .pages(let pages): state = .ready(pages: pages.count, first: pages[0])
                case .problem(let problem): state = .failed(problem)
                }
                withAnimation(.easeOut(duration: 0.18)) { items[index].state = state }
            }
        }
    }

    // MARK: State

    var isLoading: Bool {
        items.contains { $0.state == .loading }
    }

    /// Nil until every file is read, or when one can't be.
    var totalPages: Int? {
        var total = 0
        for item in items {
            guard case .ready(let pages, _) = item.state else { return nil }
            total += pages
        }
        return total
    }

    var canMerge: Bool {
        items.count >= 2 && totalPages != nil && liftedID == nil
    }

    var blockedReason: String? {
        let failed = items.filter { $0.state.isFailed }.count
        if failed > 0 { return failed == 1 ? "Remove the marked PDF to merge." : "Remove the marked PDFs to merge." }
        if items.count < 2, !isLoading { return "Merging needs two or more PDFs." }
        return nil
    }

    // MARK: Editing

    func move(_ id: Int, by step: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + step) else { return }
        withAnimation(PDFToolKit.motion(reduceMotion)) { items.swapAt(index, index + step) }
    }

    func remove(_ id: Int) {
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            items.removeAll { $0.id == id }
        }
    }

    // MARK: Dragging

    func dragChanged(from start: CGPoint, to location: CGPoint) {
        guard !ignoringGesture else { return }
        if liftedID == nil || settling {
            endLift()
            // Only a drag that starts on a row moves anything.
            guard let index = Self.rows.slot(at: start, count: items.count) else {
                ignoringGesture = true
                return
            }
            let top = Self.rows.origin(of: index).y
            grab = start.y - top
            liftY = top
            liftedID = items[index].id
            autoScroller.start { [weak self] in self?.autoScroll() }
        }
        pointerY = location.y
        follow()
    }

    func dragEnded() {
        ignoringGesture = false
        guard let id = liftedID, !settling else { return }
        autoScroller.stop()
        guard let index = items.firstIndex(where: { $0.id == id }),
              let animation = PDFToolKit.motion(reduceMotion) else {
            endLift()
            return
        }
        // Settle into the slot, then swap the lifted copy back for the row.
        withAnimation(animation) {
            settling = true
            liftY = Self.rows.origin(of: index).y
        } completion: { [weak self] in
            guard let self, self.settling, self.liftedID == id else { return }
            self.endLift()
        }
    }

    private func endLift() {
        liftedID = nil
        settling = false
    }

    /// The lifted row follows the pointer; the others make room as it passes their middle.
    private func follow() {
        guard let id = liftedID else { return }
        let height = max(Self.rows.height(count: items.count), Self.shortest)
        liftY = min(max(pointerY - grab, -6), height - Self.rows.cell.height + 6)
        let middle = CGPoint(x: Self.rows.cell.width / 2, y: liftY + Self.rows.cell.height / 2)
        let target = Self.rows.nearest(to: middle, count: items.count)
        if let current = items.firstIndex(where: { $0.id == id }), current != target {
            withAnimation(PDFToolKit.motion(reduceMotion)) {
                items = PDFToolKit.moving(items, [id], to: target)
            }
        }
    }

    private func autoScroll() {
        guard liftedID != nil, !settling else { return }
        let speed = PDFToolKit.AutoScroller.speed(pointer: pointerY - scroll.offset, viewport: scroll.viewport)
        guard speed != 0 else { return }
        let offset = min(max(scroll.offset + speed, 0), scroll.maxOffset)
        let delta = offset - scroll.offset
        guard abs(delta) > 0.01 else { return }
        scroll.offset = offset
        scrollPosition.scrollTo(y: offset)
        pointerY += delta
        follow()
    }
}

// MARK: - List

private struct MergeList: View {
    @Bindable var model: MergeModel

    var body: some View {
        let count = model.items.count
        let content = MergeModel.rows.height(count: count)
        let visible = min(max(content, MergeModel.shortest), MergeModel.tallest)
        ScrollView {
            VStack(spacing: MergeModel.rows.spacing.height) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    MergeSlot(model: model, item: item, index: index, count: count,
                              lifted: model.liftedID == item.id)
                }
            }
            .frame(width: MergeModel.rows.cell.width)
            .frame(minHeight: visible, alignment: .top)
            .contentShape(Rectangle())
            .coordinateSpace(.named(MergeModel.space))
            .overlay(alignment: .topLeading) { LiftedRow(model: model) }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(MergeModel.space))
                    .onChanged { model.dragChanged(from: $0.startLocation, to: $0.location) }
                    .onEnded { _ in model.dragEnded() }
            )
        }
        .scrollPosition($model.scrollPosition)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(content > visible ? .automatic : .never)
        .onScrollGeometryChange(for: PDFToolKit.ScrollMetrics.self) { geometry in
            PDFToolKit.ScrollMetrics(offset: geometry.contentOffset.y, viewport: geometry.containerSize.height,
                                     content: geometry.contentSize.height)
        } action: { _, metrics in
            model.scroll = metrics
        }
        .frame(height: visible)
        .onHover { model.link.pointerOverReorderArea($0) }
    }
}

private struct MergeSlot: View {
    let model: MergeModel
    let item: MergeModel.Item
    let index: Int
    let count: Int
    let lifted: Bool

    var body: some View {
        Group {
            if lifted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PDFToolKit.Look.well)
                    .frame(width: MergeModel.rows.cell.width, height: MergeModel.rows.cell.height)
            } else {
                MergeRow(model: model, item: item, index: index, count: count)
            }
        }
        .transition(.opacity)
    }
}

private struct LiftedRow: View {
    let model: MergeModel

    var body: some View {
        if let id = model.liftedID, let index = model.items.firstIndex(where: { $0.id == id }) {
            RaisedRow(model: model, item: model.items[index], index: index, count: model.items.count)
                .id(id)
                .offset(y: model.liftY)
                .allowsHitTesting(false)
        }
    }
}

/// Rises off the list when picked up, and lands flat again when let go.
private struct RaisedRow: View {
    let model: MergeModel
    let item: MergeModel.Item
    let index: Int
    let count: Int
    @State private var raised = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MergeRow(model: model, item: item, index: index, count: count, lifted: raised && !model.settling)
            .onAppear {
                withAnimation(PDFToolKit.motion(reduceMotion)) { raised = true }
            }
    }
}

private struct MergeRow: View {
    let model: MergeModel
    let item: MergeModel.Item
    let index: Int
    let count: Int
    var lifted = false

    var body: some View {
        HStack(spacing: 0) {
            Text("\(index + 1)")
                .font(PDFToolKit.Look.text)
                .monospacedDigit()
                .foregroundStyle(ToolStyle.secondary)
                .contentTransition(.numericText(value: Double(index + 1)))
                .frame(width: 32)
            FirstPage(item: item)
                .frame(width: 24, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(PDFToolKit.Look.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state.isFailed {
                Button { model.remove(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from this merge")
                .padding(.leading, 6)
            }
            VStack(spacing: 2) {
                Button { model.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(StepButtonStyle())
                    .disabled(index == 0)
                    .help("Move up")
                Button { model.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(StepButtonStyle())
                    .disabled(index >= count - 1)
                    .help("Move down")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
        }
        .frame(width: MergeModel.rows.cell.width, height: MergeModel.rows.cell.height)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(lifted ? PDFToolKit.Look.card : PDFToolKit.Look.well)
                .shadow(color: .black.opacity(lifted ? 0.16 : 0), radius: lifted ? 8 : 0, y: lifted ? 3 : 0)
        }
        .scaleEffect(lifted ? 1.02 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index + 1), \(item.url.lastPathComponent), \(accessibilityDetail)")
        .accessibilityAction(named: "Move up") { model.move(item.id, by: -1) }
        .accessibilityAction(named: "Move down") { model.move(item.id, by: 1) }
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .loading:
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 38, height: 6)
                .padding(.vertical, 3)
        case .ready(let pages, _):
            Text(PDFToolKit.pageCount(pages))
                .font(PDFToolKit.Look.note)
                .foregroundStyle(ToolStyle.secondary)
        case .failed(let problem):
            Text(problem.short)
                .font(PDFToolKit.Look.note)
                .foregroundStyle(PDFToolKit.Look.failure)
        }
    }

    private var accessibilityDetail: String {
        switch item.state {
        case .loading: "loading"
        case .ready(let pages, _): PDFToolKit.pageCount(pages)
        case .failed(let problem): problem.short
        }
    }
}

/// The first page in miniature. Before it's read, the same page glyph the original shows.
private struct FirstPage: View {
    let item: MergeModel.Item

    var body: some View {
        switch item.state {
        case .ready(_, let first):
            let size = PDFToolKit.fit(first.displaySize, angle: 0, in: CGSize(width: 20, height: 26)).page
            PDFToolKit.Thumbnail(reader: item.reader, page: 0, pixels: CGSize(width: 60, height: 78))
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
                .transition(.opacity)
        case .failed(let problem):
            Image(systemName: problem == .locked ? "lock.doc" : "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(ToolStyle.secondary)
        case .loading:
            Image(systemName: "richtext.page")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The small stacked up and down buttons at the end of each row.
private struct StepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StepButton(configuration: configuration)
    }

    private struct StepButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary.opacity(isEnabled ? 0.72 : 0.2))
                .frame(width: 32, height: 13)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(fill))
                }
                .padding(.vertical, 1.25)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var fill: Double {
            guard isEnabled else { return 0.025 }
            if configuration.isPressed { return 0.17 }
            return hovering ? 0.11 : 0.075
        }
    }
}
