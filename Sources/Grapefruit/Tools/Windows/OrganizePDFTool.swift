import AppKit
import SwiftUI

/// Organize PDF: every page as a card to reorder, turn, duplicate or remove, then a new PDF
/// called "name Organized.pdf" next to the original.
/// Layout measured from the original window: 560pt wide, four 123pt columns 12pt apart,
/// an orange page number top left of each card and a rotate button top right.
struct OrganizePDFTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @State private var model: OrganizeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: ToolSession) {
        self.session = session
        _model = State(initialValue: OrganizeModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: 560, onClose: session.close) {
            VStack(alignment: .leading, spacing: 0) {
                OrganizeHeader(model: model)
                    .frame(height: 16)
                    .padding(.top, -3)
                PageGrid(model: model)
                    .padding(.top, 6)
                Divider()
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Make all pages the same width", isOn: $model.sameWidth)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(!model.isReady)
                    Text("Pages are scaled proportionally to match the narrowest page; their heights may still differ.")
                        .font(PDFToolKit.Look.note)
                        .foregroundStyle(ToolStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: "Save Organized PDF",
                       primaryEnabled: model.canSave, onPrimary: save)
        }
        .background(PDFToolKit.WindowReader { model.attach($0) })
        .task { await model.load() }
        .onChange(of: reduceMotion, initial: true) { _, reduce in model.reduceMotion = reduce }
    }

    private func save() {
        guard model.canSave else { return }
        let plan = model.pages.map {
            PDFToolKit.PlannedPage(source: $0.source, rotation: PDFToolKit.normalized($0.rotation))
        }
        let source = session.url
        let sameWidth = model.sameWidth
        let name = Output.name(source, suffix: session.tool.outputSuffix, ext: "pdf")
        model.close()
        session.run([
            JobStep(name: source.lastPathComponent, destination: source.deletingLastPathComponent()) { ctx in
                let out = ctx.output(name)
                try PDFToolKit.organize(source, pages: plan, sameWidth: sameWidth, to: out, ctx: ctx)
                return [out]
            }
        ])
    }
}

// MARK: - Model

@MainActor
@Observable
private final class OrganizeModel {
    struct Page: Identifiable, Equatable {
        let id: Int
        let source: Int
        /// Clockwise degrees on top of the file's own rotation. Never wrapped, so a fourth
        /// turn keeps going forward instead of spinning all the way back.
        var rotation: Int
    }

    enum Phase: Equatable {
        case loading, ready
        case failed(PDFToolKit.Problem)
    }

    static let grid = PDFToolKit.GridMetrics(columns: 4, cell: CGSize(width: 123, height: 159),
                                             spacing: CGSize(width: 12, height: 12), inset: CGPoint(x: 4, y: 8))
    static let width: CGFloat = 536
    static let visibleHeight: CGFloat = 414
    /// Room for the page inside a card (6pt of card around it), and the least a card shrinks to
    /// so its number and rotate button still fit beside each other.
    static let pageBox = CGSize(width: 111, height: 147)
    static let smallestPage = CGSize(width: 52, height: 30)
    static let cardInset: CGFloat = 6
    /// Thumbnails at twice the card size either way up, so a turned page stays sharp.
    static let thumbnailPixels = CGSize(width: 294, height: 294)
    static let space = "organize.grid"

    let url: URL
    let reader: PDFToolKit.Reader
    var phase: Phase = .loading
    var showsSpinner = false
    private(set) var infos: [PDFToolKit.PageInfo] = []
    var pages: [Page] = []
    private(set) var original: [Page] = []
    var selection: Set<Int> = []
    var sameWidth = false
    /// Pages picked up by a drag. Their slots show as empty wells while a lifted card follows
    /// the pointer. The position changes on every mouse move, so it's kept apart from the rest.
    var liftedIDs: Set<Int> = []
    var liftLead: Int?
    var liftOrigin = CGPoint.zero
    var settling = false
    var scrollPosition = ScrollPosition(edge: .top)
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var scroll = PDFToolKit.ScrollMetrics()
    @ObservationIgnored let link = PDFToolKit.WindowLink()
    @ObservationIgnored private(set) var liftOrder: [Int] = []
    @ObservationIgnored private let autoScroller = PDFToolKit.AutoScroller()
    @ObservationIgnored private var anchor: Int?
    @ObservationIgnored private var focus: Int?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var undoStack: [[Page]] = []
    @ObservationIgnored private var redoStack: [[Page]] = []
    @ObservationIgnored private var grab = CGSize.zero
    @ObservationIgnored private var pointer = CGPoint.zero
    @ObservationIgnored private var dragBefore: [Page] = []
    @ObservationIgnored private var ignoringGesture = false
    @ObservationIgnored private var loadStarted = false

    init(url: URL) {
        self.url = url
        reader = PDFToolKit.Reader(url: url, cacheLimit: 96 << 20)
    }

    func attach(_ window: NSWindow) {
        guard link.window !== window else { return }
        link.attach(window)
        link.handleKeys { [weak self] event in self?.handleKey(event) ?? false }
        link.whenClosed { [weak self] in self?.autoScroller.stop() }
    }

    func close() {
        autoScroller.stop()
        link.detach()
    }

    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        // A spinner only if reading takes a moment, so quick files never flash one.
        let spinner = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, self.phase == .loading else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.showsSpinner = true }
        }
        let contents = await reader.contents()
        spinner.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showsSpinner = false
            switch contents {
            case .pages(let infos):
                self.infos = infos
                original = infos.indices.map { Page(id: $0, source: $0, rotation: 0) }
                nextID = infos.count
                pages = original
                phase = .ready
            case .problem(let problem):
                phase = .failed(problem)
            }
        }
    }

    // MARK: State

    var isReady: Bool { phase == .ready }

    var canSave: Bool {
        phase == .ready && !pages.isEmpty && liftLead == nil
    }

    var isModified: Bool {
        pages.count != original.count
            || zip(pages, original).contains { $0.id != $1.id || PDFToolKit.normalized($0.rotation) != 0 }
    }

    var summary: String {
        guard phase == .ready else { return "" }
        if selection.isEmpty { return PDFToolKit.pageCount(pages.count) }
        return "\(selection.count.formatted()) of \(pages.count.formatted()) selected"
    }

    func info(for page: Page) -> PDFToolKit.PageInfo {
        infos.indices.contains(page.source)
            ? infos[page.source]
            : PDFToolKit.PageInfo(size: CGSize(width: 612, height: 792), rotation: 0)
    }

    /// A card's size when still: the turned page fitted to the card, plus the card around it.
    static func cardSize(_ info: PDFToolKit.PageInfo, rotation: Double) -> CGSize {
        let room = PDFToolKit.fit(info.displaySize, angle: rotation, in: pageBox).bounds
        return CGSize(width: max(room.width, smallestPage.width) + cardInset * 2,
                      height: max(room.height, smallestPage.height) + cardInset * 2)
    }

    private func index(of id: Int) -> Int? {
        pages.firstIndex { $0.id == id }
    }

    /// The card under `point`, using the card's own outline rather than its whole slot.
    private func cardIndex(at point: CGPoint) -> Int? {
        guard let index = Self.grid.slot(at: point, count: pages.count) else { return nil }
        let slot = Self.grid.frame(of: index)
        let size = Self.cardSize(info(for: pages[index]), rotation: Double(pages[index].rotation))
        let card = CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                          width: size.width, height: size.height)
        return card.insetBy(dx: -3, dy: -3).contains(point) ? index : nil
    }

    // MARK: Selection

    /// The selection when `id` is part of it, otherwise just that page.
    func targets(for id: Int) -> Set<Int> {
        selection.contains(id) ? selection : [id]
    }

    func click(at point: CGPoint) {
        guard phase == .ready else { return }
        guard let index = cardIndex(at: point) else {
            setSelection([])
            anchor = nil
            focus = nil
            return
        }
        let id = pages[index].id
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var next = selection
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            setSelection(next)
            anchor = id
            focus = id
        } else if flags.contains(.shift), let anchor, let start = self.index(of: anchor) {
            setSelection(Set(pages[min(start, index)...max(start, index)].map(\.id)))
            focus = id
        } else {
            setSelection([id])
            anchor = id
            focus = id
        }
    }

    func selectAll() {
        setSelection(Set(pages.map(\.id)))
        anchor = pages.first?.id
        focus = pages.last?.id
    }

    private func setSelection(_ ids: Set<Int>) {
        guard ids != selection else { return }
        withAnimation(.easeOut(duration: 0.12)) { selection = ids }
    }

    /// Arrow keys: move to the next card, or grow the selection with Shift.
    private func moveFocus(by step: Int, extend: Bool) {
        guard !pages.isEmpty else { return }
        var next: Int
        if let focus, let current = index(of: focus) {
            next = current + step
        } else {
            next = step > 0 ? 0 : pages.count - 1
        }
        next = min(max(next, 0), pages.count - 1)
        let id = pages[next].id
        focus = id
        if extend, let anchor, let start = index(of: anchor) {
            setSelection(Set(pages[min(start, next)...max(start, next)].map(\.id)))
        } else {
            anchor = id
            setSelection([id])
        }
        reveal(next)
    }

    /// Scrolls just enough to show a card.
    private func reveal(_ index: Int) {
        let frame = Self.grid.frame(of: index)
        var target: CGFloat?
        if frame.minY - 8 < scroll.offset {
            target = frame.minY - 8
        } else if frame.maxY + 8 > scroll.offset + scroll.viewport {
            target = frame.maxY + 8 - scroll.viewport
        }
        guard let target else { return }
        let y = min(max(target, 0), scroll.maxOffset)
        withAnimation(PDFToolKit.motion(reduceMotion)) { scrollPosition.scrollTo(y: y) }
    }

    // MARK: Editing

    func rotate(_ ids: Set<Int>, by degrees: Int) {
        guard phase == .ready, !ids.isEmpty else { return }
        remember(pages)
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            for i in pages.indices where ids.contains(pages[i].id) {
                pages[i].rotation += degrees
            }
        }
    }

    /// Each copy lands right after its page, and the copies end up selected.
    func duplicate(_ ids: Set<Int>) {
        guard phase == .ready, !ids.isEmpty else { return }
        remember(pages)
        var result: [Page] = []
        var copies: [Int] = []
        for page in pages {
            result.append(page)
            if ids.contains(page.id) {
                let copy = Page(id: nextID, source: page.source, rotation: page.rotation)
                nextID += 1
                result.append(copy)
                copies.append(copy.id)
            }
        }
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            pages = result
            selection = Set(copies)
        }
        anchor = copies.first
        focus = copies.last
    }

    func delete(_ ids: Set<Int>) {
        guard phase == .ready, !ids.isEmpty else { return }
        remember(pages)
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            pages.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
        }
        if let anchor, ids.contains(anchor) { self.anchor = nil }
        if let focus, ids.contains(focus) { self.focus = nil }
    }

    /// Back to the file as it was: every page, in order, unturned.
    func reset() {
        guard phase == .ready, isModified else { return }
        remember(pages)
        let turned = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.rotation) })
        let restored = original.map { page -> Page in
            var page = page
            // Turn back the short way: to the full turn nearest where the card is now.
            if let rotation = turned[page.id] { page.rotation = Int((Double(rotation) / 360).rounded()) * 360 }
            return page
        }
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            pages = restored
            selection = []
        }
        anchor = nil
        focus = nil
    }

    private func remember(_ snapshot: [Page]) {
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pages)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pages)
        restore(next)
    }

    private func restore(_ snapshot: [Page]) {
        let ids = Set(snapshot.map(\.id))
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            pages = snapshot
            selection.formIntersection(ids)
        }
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
        if let focus, !ids.contains(focus) { self.focus = nil }
    }

    // MARK: Keys

    /// Delete removes, arrows move the selection (Shift extends), ⌘A selects all,
    /// ⌘L and ⌘R turn left and right like Preview, ⌘D duplicates, ⌘Z and ⇧⌘Z undo and redo.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard phase == .ready, liftLead == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        if !command {
            switch event.keyCode {
            case 51, 117:
                guard !selection.isEmpty else { return false }
                delete(selection)
                return true
            case 123: moveFocus(by: -1, extend: shift); return true
            case 124: moveFocus(by: 1, extend: shift); return true
            case 126: moveFocus(by: -Self.grid.columns, extend: shift); return true
            case 125: moveFocus(by: Self.grid.columns, extend: shift); return true
            default: return false
            }
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where !shift:
            selectAll()
        case "z":
            if shift { redo() } else { undo() }
        case "d" where !shift && !selection.isEmpty:
            duplicate(selection)
        case "l" where !shift && !selection.isEmpty:
            rotate(selection, by: -90)
        case "r" where !shift && !selection.isEmpty:
            rotate(selection, by: 90)
        default:
            return false
        }
        return true
    }

    // MARK: Dragging

    func dragChanged(from start: CGPoint, to location: CGPoint) {
        guard phase == .ready, !ignoringGesture else { return }
        if liftLead == nil || settling {
            endLift()
            // Only a drag that starts on a card moves anything.
            guard let index = cardIndex(at: start) else {
                ignoringGesture = true
                return
            }
            beginLift(at: index, start: start)
        }
        pointer = location
        follow()
    }

    func dragEnded() {
        ignoringGesture = false
        guard let lead = liftLead, !settling else { return }
        autoScroller.stop()
        if pages != dragBefore { remember(dragBefore) }
        guard let index = index(of: lead), let animation = PDFToolKit.motion(reduceMotion) else {
            endLift()
            return
        }
        // Settle into the slot, then swap the lifted card back for the real one.
        // Pages carried along drop into their slots as it lands.
        withAnimation(animation) {
            settling = true
            liftOrigin = Self.grid.origin(of: index)
            liftedIDs = [lead]
        } completion: { [weak self] in
            guard let self, self.settling, self.liftLead == lead else { return }
            self.endLift()
        }
    }

    /// Dragging a selected card carries the whole selection; any other card goes alone.
    private func beginLift(at index: Int, start: CGPoint) {
        let lead = pages[index].id
        if !selection.contains(lead) {
            selection = [lead]
            anchor = lead
            focus = lead
        }
        let origin = Self.grid.origin(of: index)
        grab = CGSize(width: start.x - origin.x, height: start.y - origin.y)
        dragBefore = pages
        liftOrder = pages.filter { selection.contains($0.id) }.map(\.id)
        liftLead = lead
        liftOrigin = origin
        // The lifted card covers its own slot; the other pages it carries fade out of theirs.
        let carried = Set(liftOrder)
        if reduceMotion {
            liftedIDs = carried
        } else {
            withAnimation(.easeOut(duration: 0.15)) { liftedIDs = carried }
        }
        autoScroller.start { [weak self] in self?.autoScroll() }
    }

    private func endLift() {
        liftedIDs = []
        liftLead = nil
        liftOrder = []
        settling = false
    }

    /// The lifted card follows the pointer; the pages it carries take the slots around the
    /// one under its middle, and the rest make room.
    private func follow() {
        guard let lead = liftLead else { return }
        let height = max(Self.grid.height(count: pages.count), Self.visibleHeight)
        let cell = Self.grid.cell
        liftOrigin = CGPoint(x: min(max(pointer.x - grab.width, -8), Self.width - cell.width + 8),
                             y: min(max(pointer.y - grab.height, -8), height - cell.height + 8))
        let middle = CGPoint(x: liftOrigin.x + cell.width / 2, y: liftOrigin.y + cell.height / 2)
        let carried = liftOrder.count
        let leadOffset = liftOrder.firstIndex(of: lead) ?? 0
        let start = min(max(Self.grid.nearest(to: middle, count: pages.count) - leadOffset, 0), pages.count - carried)
        let inPlace = start + carried <= pages.count && pages[start..<(start + carried)].map(\.id) == liftOrder
        guard !inPlace else { return }
        withAnimation(PDFToolKit.motion(reduceMotion)) {
            pages = PDFToolKit.moving(pages, Set(liftOrder), to: start)
        }
    }

    private func autoScroll() {
        guard liftLead != nil, !settling else { return }
        let speed = PDFToolKit.AutoScroller.speed(pointer: pointer.y - scroll.offset, viewport: scroll.viewport)
        guard speed != 0 else { return }
        let offset = min(max(scroll.offset + speed, 0), scroll.maxOffset)
        let delta = offset - scroll.offset
        guard abs(delta) > 0.01 else { return }
        scroll.offset = offset
        scrollPosition.scrollTo(y: offset)
        pointer.y += delta
        follow()
    }
}

// MARK: - Header

private struct OrganizeHeader: View {
    let model: OrganizeModel

    var body: some View {
        HStack(spacing: 2) {
            Text(model.summary)
                .font(PDFToolKit.Look.text)
                .monospacedDigit()
                .foregroundStyle(ToolStyle.secondary)
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            if !model.selection.isEmpty {
                Group {
                    IconButton(symbol: "rotate.left", label: "Rotate left", shortcut: "⌘L") {
                        model.rotate(model.selection, by: -90)
                    }
                    IconButton(symbol: "rotate.right", label: "Rotate right", shortcut: "⌘R") {
                        model.rotate(model.selection, by: 90)
                    }
                    IconButton(symbol: "plus.square.on.square", label: "Duplicate", shortcut: "⌘D") {
                        model.duplicate(model.selection)
                    }
                    IconButton(symbol: "trash", label: "Delete", shortcut: "⌫") {
                        model.delete(model.selection)
                    }
                }
                .transition(.opacity)
            }
            Button("Reset Order") { model.reset() }
                .controlSize(.mini)
                .disabled(!model.isModified)
                .padding(.leading, 8)
        }
        .animation(.easeOut(duration: 0.14), value: model.selection.isEmpty)
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(IconButtonStyle())
        .help("\(label)  \(shortcut)")
        .accessibilityLabel(label)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration)
    }

    private struct Icon: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : ToolStyle.secondary)
                .frame(width: 24, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0))
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - Grid

private struct PageGrid: View {
    @Bindable var model: OrganizeModel

    private let columns = Array(repeating: GridItem(.fixed(OrganizeModel.grid.cell.width),
                                                    spacing: OrganizeModel.grid.spacing.width),
                                count: OrganizeModel.grid.columns)

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: OrganizeModel.grid.spacing.height) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                        PageSlot(model: model, page: page, number: index + 1,
                                 selected: model.selection.contains(page.id),
                                 lifted: model.liftedIDs.contains(page.id))
                    }
                }
                .padding(.horizontal, OrganizeModel.grid.inset.x)
                .padding(.vertical, OrganizeModel.grid.inset.y)
                .frame(width: OrganizeModel.width, alignment: .topLeading)
                .frame(minHeight: OrganizeModel.visibleHeight, alignment: .top)
                .contentShape(Rectangle())
                .coordinateSpace(.named(OrganizeModel.space))
                .overlay(alignment: .topLeading) { LiftedCards(model: model) }
                .gesture(
                    SimultaneousGesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(OrganizeModel.space)),
                        SpatialTapGesture(coordinateSpace: .named(OrganizeModel.space))
                    )
                    .onChanged { value in
                        if let drag = value.first { model.dragChanged(from: drag.startLocation, to: drag.location) }
                    }
                    .onEnded { value in
                        if value.first != nil {
                            model.dragEnded()
                        } else if let tap = value.second {
                            model.click(at: tap.location)
                        }
                    }
                )
            }
            .scrollPosition($model.scrollPosition)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: PDFToolKit.ScrollMetrics.self) { geometry in
                PDFToolKit.ScrollMetrics(offset: geometry.contentOffset.y, viewport: geometry.containerSize.height,
                                         content: geometry.contentSize.height)
            } action: { _, metrics in
                model.scroll = metrics
            }

            GridMessage(model: model)
                .allowsHitTesting(false)
        }
        .frame(height: OrganizeModel.visibleHeight)
        .onHover { model.link.pointerOverReorderArea($0) }
    }
}

/// Loading, a file that can't be opened, or every page removed.
private struct GridMessage: View {
    let model: OrganizeModel

    var body: some View {
        switch model.phase {
        case .loading:
            if model.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
        case .failed(let problem):
            VStack(spacing: 8) {
                Image(systemName: problem.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(problem.message)
                    .font(.system(size: 12))
                    .foregroundStyle(ToolStyle.secondary)
            }
        case .ready:
            if model.pages.isEmpty {
                VStack(spacing: 4) {
                    Text("No pages left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ToolStyle.secondary)
                    Text("Use Reset Order or ⌘Z to bring them back.")
                        .font(PDFToolKit.Look.note)
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
        }
    }
}

private struct PageSlot: View {
    let model: OrganizeModel
    let page: OrganizeModel.Page
    let number: Int
    let selected: Bool
    let lifted: Bool

    var body: some View {
        Group {
            if lifted {
                let size = OrganizeModel.cardSize(model.info(for: page), rotation: Double(page.rotation))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PDFToolKit.Look.well)
                    .frame(width: size.width, height: size.height)
            } else {
                PageCard(model: model, page: page, number: number, selected: selected)
                    .contextMenu {
                        Button("Rotate Left") { model.rotate(model.targets(for: page.id), by: -90) }
                        Button("Rotate Right") { model.rotate(model.targets(for: page.id), by: 90) }
                        Divider()
                        Button("Duplicate") { model.duplicate(model.targets(for: page.id)) }
                        Button("Delete") { model.delete(model.targets(for: page.id)) }
                    }
            }
        }
        .frame(width: OrganizeModel.grid.cell.width, height: OrganizeModel.grid.cell.height)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

/// The card under the pointer while dragging, with the edges of the others it carries peeking out.
private struct LiftedCards: View {
    let model: OrganizeModel

    var body: some View {
        if let lead = model.liftLead, let index = model.pages.firstIndex(where: { $0.id == lead }) {
            LiftedStack(model: model, page: model.pages[index], number: index + 1)
                .id(lead)
                .offset(x: model.liftOrigin.x, y: model.liftOrigin.y)
                .allowsHitTesting(false)
        }
    }
}

/// Rises off the grid when picked up, and lands flat again when let go.
private struct LiftedStack: View {
    let model: OrganizeModel
    let page: OrganizeModel.Page
    let number: Int
    @State private var raised = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let carried = model.liftOrder.count
        let up = raised && !model.settling
        let size = OrganizeModel.cardSize(model.info(for: page), rotation: Double(page.rotation))
        ZStack {
            ForEach(1..<max(1, min(carried, 3)), id: \.self) { n in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PDFToolKit.Look.card)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .rotationEffect(.degrees(up ? (n == 1 ? 3 : -2.5) : 0))
                    .offset(x: up ? CGFloat(n) * 3 : 0, y: up ? CGFloat(n) * 3 : 0)
                    .opacity(up ? 1 : 0)
            }
            PageCard(model: model, page: page, number: number, lifted: up, carried: carried)
        }
        .frame(width: OrganizeModel.grid.cell.width, height: OrganizeModel.grid.cell.height)
        .onAppear {
            withAnimation(PDFToolKit.motion(reduceMotion)) { raised = true }
        }
    }
}

private struct PageCard: View {
    let model: OrganizeModel
    let page: OrganizeModel.Page
    let number: Int
    var selected = false
    /// Following the pointer.
    var lifted = false
    /// Pages moving together, this one included.
    var carried = 1
    @State private var hovering = false

    var body: some View {
        let info = model.info(for: page)
        PDFToolKit.Thumbnail(reader: model.reader, page: page.source, pixels: OrganizeModel.thumbnailPixels)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            }
            .modifier(TurnedPage(angle: Double(page.rotation), page: info.displaySize))
            .padding(OrganizeModel.cardInset)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PDFToolKit.Look.card)
                    .shadow(color: .black.opacity(lifted ? 0.2 : hovering ? 0.13 : 0.09),
                            radius: lifted ? 12 : hovering ? 3 : 1.5, y: lifted ? 6 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(ToolStyle.orange, lineWidth: 2.5)
                    .padding(-3)
                    .opacity(selected ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                Badge(text: number.formatted(), value: number)
                    .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                if lifted {
                    if carried > 1 {
                        Badge(text: carried.formatted(), value: carried, dark: true)
                            .padding(7)
                    }
                } else {
                    RotateButton { model.rotate([page.id], by: 90) }
                        .padding(7)
                }
            }
            .scaleEffect(lifted ? 1.04 : 1)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(number)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: "Rotate right") { model.rotate(model.targets(for: page.id), by: 90) }
            .accessibilityAction(named: "Rotate left") { model.rotate(model.targets(for: page.id), by: -90) }
            .accessibilityAction(named: "Duplicate") { model.duplicate(model.targets(for: page.id)) }
            .accessibilityAction(named: "Delete") { model.delete(model.targets(for: page.id)) }
    }
}

/// Turns the page and resizes the card around it together, so a turn morphs the card
/// from portrait to landscape in one smooth motion.
private struct TurnedPage: ViewModifier, Animatable {
    var angle: Double
    let page: CGSize

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let fit = PDFToolKit.fit(page, angle: angle, in: OrganizeModel.pageBox)
        content
            .frame(width: fit.page.width, height: fit.page.height)
            .rotationEffect(.degrees(angle))
            .frame(width: max(fit.bounds.width, OrganizeModel.smallestPage.width),
                   height: max(fit.bounds.height, OrganizeModel.smallestPage.height))
    }
}

/// The orange page number (or, darker, how many pages a drag carries).
private struct Badge: View {
    let text: String
    let value: Int
    var dark = false

    var body: some View {
        Text(text)
            .font(PDFToolKit.Look.badge)
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText(value: Double(value)))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(dark ? Color(white: 0.32) : ToolStyle.orange))
            .fixedSize()
    }
}

private struct RotateButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "rotate.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(white: hovering ? 0.2 : 0.32)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Rotate right")
    }
}
