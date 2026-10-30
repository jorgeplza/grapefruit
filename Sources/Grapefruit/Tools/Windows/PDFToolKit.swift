import AppKit
import PDFKit
import SwiftUI

/// What the Merge PDFs and Organize PDF windows share: reading a PDF off the main thread,
/// cached page thumbnails, the work itself, and the drag, scroll and keyboard plumbing.
enum PDFToolKit {

    // MARK: - Look

    /// Measured from the original windows: compact 11pt text and 10pt notes.
    enum Look {
        static let text = Font.system(size: 11)
        static let note = Font.system(size: 10)
        static let badge = Font.system(size: 11, weight: .semibold)
        /// Rows and empty slots: a faint tint over the window background.
        static let well = Color.primary.opacity(0.04)
        static let failure = Color(nsColor: .systemRed)
        /// Page cards sit a shade lighter than the window, like paper.
        static let card = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.24, alpha: 1)
                : NSColor(white: 0.985, alpha: 1)
        })
    }

    /// Fast, settles without wobble, and never holds up the next input.
    static let spring = Animation.spring(duration: 0.26, bounce: 0.12)

    /// With Reduce Motion on, things change in place instead of sliding or spinning.
    static func motion(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }

    static func pageCount(_ n: Int) -> String {
        n == 1 ? "1 page" : "\(n.formatted()) pages"
    }

    /// 0, 90, 180 or 270.
    static func normalized(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    // MARK: - Reading

    struct PageInfo: Sendable, Equatable {
        /// Crop box size before the page's own rotation.
        var size: CGSize
        /// The rotation saved in the file.
        var rotation: Int

        init(size: CGSize, rotation: Int) {
            self.size = size
            self.rotation = PDFToolKit.normalized(rotation)
        }

        init(_ page: PDFPage) {
            self.init(size: page.bounds(for: .cropBox).size, rotation: page.rotation)
        }

        /// Size as it shows on screen.
        var displaySize: CGSize {
            rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        }
    }

    enum Problem: Error, Sendable, Equatable {
        case locked, unreadable, empty

        /// Under a file name.
        var short: String {
            switch self {
            case .locked: "Password protected"
            case .unreadable: "Can't read this file"
            case .empty: "No pages"
            }
        }

        /// On its own, in an empty window.
        var message: String {
            switch self {
            case .locked: "This PDF is password protected."
            case .unreadable: "This file can't be read as a PDF."
            case .empty: "This PDF has no pages."
            }
        }

        var symbol: String {
            switch self {
            case .locked: "lock.fill"
            case .unreadable, .empty: "exclamationmark.triangle"
            }
        }
    }

    enum Contents: Sendable {
        case pages([PageInfo])
        case problem(Problem)
    }

    /// One PDF opened once, on its own queue, for page sizes and thumbnails.
    /// PDFKit documents aren't safe to share across threads, so this one never leaves `queue`.
    final class Reader: @unchecked Sendable {
        let url: URL
        private let queue: DispatchQueue
        private let cache = NSCache<NSNumber, ImageBox>()
        // Only touched on `queue`.
        private var document: PDFDocument?
        private var problem: Problem?
        private var opened = false

        init(url: URL, cacheLimit: Int) {
            self.url = url
            queue = DispatchQueue(label: "grapefruit.pdf-reader", qos: .userInitiated)
            cache.totalCostLimit = cacheLimit
        }

        func contents() async -> Contents {
            await withCheckedContinuation { (continuation: CheckedContinuation<Contents, Never>) in
                queue.async { continuation.resume(returning: self.readContents()) }
            }
        }

        func cachedThumbnail(_ index: Int) -> CGImage? {
            cache.object(forKey: index as NSNumber)?.image
        }

        /// The page drawn on white to fit `pixels`, at the rotation saved in the file.
        /// Returns nil when the asking view went away before its turn came.
        func thumbnail(_ index: Int, fitting pixels: CGSize) async -> CGImage? {
            if let hit = cachedThumbnail(index) { return hit }
            let flag = CancelFlag()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                    queue.async {
                        if flag.isSet {
                            continuation.resume(returning: nil)
                            return
                        }
                        if let hit = self.cachedThumbnail(index) {
                            continuation.resume(returning: hit)
                            return
                        }
                        let image = autoreleasepool { self.render(index, fitting: pixels) }
                        if let image {
                            self.cache.setObject(ImageBox(image), forKey: index as NSNumber,
                                                 cost: image.bytesPerRow * image.height)
                        }
                        continuation.resume(returning: image)
                    }
                }
            } onCancel: {
                flag.set()
            }
        }

        private func open() -> PDFDocument? {
            if !opened {
                opened = true
                if let doc = PDFDocument(url: url) {
                    if doc.isLocked {
                        problem = .locked
                    } else if doc.pageCount == 0 {
                        problem = .empty
                    } else {
                        document = doc
                    }
                } else {
                    problem = .unreadable
                }
            }
            return document
        }

        private func readContents() -> Contents {
            guard let doc = open() else { return .problem(problem ?? .unreadable) }
            var pages: [PageInfo] = []
            pages.reserveCapacity(doc.pageCount)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    pages.append(PageInfo(page))
                } else {
                    pages.append(PageInfo(size: CGSize(width: 612, height: 792), rotation: 0))
                }
            }
            return .pages(pages)
        }

        private func render(_ index: Int, fitting pixels: CGSize) -> CGImage? {
            guard let page = open()?.page(at: index) else { return nil }
            let size = PageInfo(page).displaySize
            guard size.width > 0, size.height > 0 else { return nil }
            return PDFEngine.render(page, scale: min(pixels.width / size.width, pixels.height / size.height))
        }
    }

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: - The work

    /// A page of the finished document: which page of the original, turned by how much.
    struct PlannedPage: Sendable, Equatable {
        var source: Int
        /// Clockwise, on top of the rotation saved in the file.
        var rotation: Int
    }

    /// Writes the pages of `src` in the planned order and rotation.
    static func organize(_ src: URL, pages plan: [PlannedPage], sameWidth: Bool, to out: URL, ctx: JobContext) throws {
        guard !plan.isEmpty else { throw JobError.failed("There are no pages to save.") }
        let doc = try openForWork(src)
        var pages: [PDFPage] = []
        pages.reserveCapacity(plan.count)
        for (n, item) in plan.enumerated() {
            try ctx.checkCancelled()
            guard let page = doc.page(at: item.source)?.copy() as? PDFPage else {
                throw JobError.failed("Couldn't read page \(item.source + 1).")
            }
            page.rotation = normalized(page.rotation + item.rotation)
            pages.append(page)
            ctx.progress(0.4 * Double(n + 1) / Double(plan.count))
        }

        var keepAlive: [PDFDocument] = []
        var redrawn = Set<Int>()
        if sameWidth {
            try matchNarrowest(&pages, redrawn: &redrawn, keepAlive: &keepAlive, ctx: ctx, progress: 0.4...0.85)
        }

        let result = PDFDocument()
        for page in pages { result.insert(page, at: result.pageCount) }
        if let attributes = doc.documentAttributes { result.documentAttributes = attributes }

        // Bookmarks follow their page to its first new position. Ones whose page is gone are dropped.
        if let own = doc.outlineRoot, own.numberOfChildren > 0 {
            var firstPosition: [Int: Int] = [:]
            for (n, item) in plan.enumerated() where firstPosition[item.source] == nil {
                firstPosition[item.source] = n
            }
            let root = PDFOutline()
            copyOutline(own, of: doc, into: root, target: result,
                        map: { firstPosition[$0] }, keepsPoint: { !redrawn.contains($0) })
            if root.numberOfChildren > 0 { result.outlineRoot = root }
        }

        try ctx.checkCancelled()
        ctx.progress(0.9)
        guard result.write(to: out) else { throw JobError.failed("Couldn't save the PDF.") }
        withExtendedLifetime((doc, keepAlive)) {}
    }

    /// Several PDFs, one after another, with a bookmark per file holding that file's own bookmarks.
    static func merge(_ sources: [URL], to out: URL, ctx: JobContext) throws {
        var documents: [PDFDocument] = []
        for url in sources {
            try ctx.checkCancelled()
            documents.append(try openForWork(url))
        }
        let total = max(1, documents.reduce(0) { $0 + $1.pageCount })
        let merged = PDFDocument()
        var starts: [Int] = []
        var done = 0
        for (n, doc) in documents.enumerated() {
            starts.append(merged.pageCount)
            for i in 0..<doc.pageCount {
                try ctx.checkCancelled()
                guard let page = doc.page(at: i)?.copy() as? PDFPage else {
                    throw JobError.failed("Couldn't read page \(i + 1) of “\(sources[n].lastPathComponent)”.")
                }
                merged.insert(page, at: merged.pageCount)
                done += 1
                ctx.progress(0.85 * Double(done) / Double(total))
            }
        }

        let root = PDFOutline()
        for (n, doc) in documents.enumerated() {
            guard let first = merged.page(at: starts[n]) else { continue }
            let entry = PDFOutline()
            entry.label = Output.stem(sources[n])
            entry.destination = PDFDestination(page: first, at: unspecifiedPoint)
            if let own = doc.outlineRoot, own.numberOfChildren > 0 {
                let offset = starts[n]
                copyOutline(own, of: doc, into: entry, target: merged, map: { offset + $0 }, keepsPoint: { _ in true })
            }
            root.insertChild(entry, at: root.numberOfChildren)
        }
        merged.outlineRoot = root

        try ctx.checkCancelled()
        ctx.progress(0.9)
        guard merged.write(to: out) else { throw JobError.failed("Couldn't save the merged PDF.") }
        withExtendedLifetime(documents) {}
    }

    static func openForWork(_ url: URL) throws -> PDFDocument {
        let name = url.lastPathComponent
        guard let doc = PDFDocument(url: url) else { throw JobError.failed("Couldn't open “\(name)”.") }
        if doc.isLocked { throw JobError.failed("“\(name)” is password protected.") }
        guard doc.pageCount > 0 else { throw JobError.failed("“\(name)” has no pages.") }
        return doc
    }

    static func displaySize(of page: PDFPage) -> CGSize {
        PageInfo(page).displaySize
    }

    /// Scales every page wider than the narrowest one down to its width. Heights keep their proportion.
    static func matchNarrowest(_ pages: inout [PDFPage], redrawn: inout Set<Int>, keepAlive: inout [PDFDocument],
                               ctx: JobContext, progress: ClosedRange<Double>) throws {
        let widths = pages.map { displaySize(of: $0).width }
        guard let narrowest = widths.filter({ $0 > 0 }).min() else { return }
        let wider = pages.indices.filter { widths[$0] - narrowest > 0.5 }
        for (n, i) in wider.enumerated() {
            try ctx.checkCancelled()
            guard let (holder, page) = scaledCopy(of: pages[i], scale: narrowest / widths[i]) else {
                throw JobError.failed("Couldn't resize page \(i + 1).")
            }
            keepAlive.append(holder)
            pages[i] = page
            redrawn.insert(i)
            let span = progress.upperBound - progress.lowerBound
            ctx.progress(progress.lowerBound + span * Double(n + 1) / Double(wider.count))
        }
    }

    /// A vector copy of `page` at `scale`, its rotation drawn in. Text stays text; annotations are drawn flat.
    static func scaledCopy(of page: PDFPage, scale: CGFloat) -> (PDFDocument, PDFPage)? {
        let size = displaySize(of: page)
        var box = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let data = NSMutableData()
        guard box.width > 0, box.height > 0,
              let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.endPDFPage()
        context.closePDF()
        guard let doc = PDFDocument(data: data as Data), let copy = doc.page(at: 0) else { return nil }
        return (doc, copy)
    }

    static let unspecifiedPoint = CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)

    /// Copies the bookmarks under `node` into `parent`, pointing at the pages they map to in `target`.
    /// `keepsPoint` says whether a target page kept its coordinates (redrawn pages didn't).
    static func copyOutline(_ node: PDFOutline, of source: PDFDocument, into parent: PDFOutline, target: PDFDocument,
                            map: (Int) -> Int?, keepsPoint: (Int) -> Bool) {
        for c in 0..<node.numberOfChildren {
            guard let child = node.child(at: c) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            var points = false
            if let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination,
               let page = destination.page {
                let index = source.index(for: page)
                if index != NSNotFound, let mapped = map(index), let newPage = target.page(at: mapped) {
                    let moved = PDFDestination(page: newPage, at: keepsPoint(mapped) ? destination.point : unspecifiedPoint)
                    moved.zoom = destination.zoom
                    copy.destination = moved
                    points = true
                }
            } else if let link = child.action as? PDFActionURL, let url = link.url {
                copy.action = PDFActionURL(url: url)
                points = true
            }
            copyOutline(child, of: source, into: copy, target: target, map: map, keepsPoint: keepsPoint)
            if points || copy.numberOfChildren > 0 {
                parent.insertChild(copy, at: parent.numberOfChildren)
                copy.isOpen = child.isOpen
            }
        }
    }

    // MARK: - Layout

    /// A page turned by `angle` degrees and shrunk to fit `box`:
    /// the page's own size, and the room it takes once turned.
    static func fit(_ page: CGSize, angle: Double, in box: CGSize) -> (page: CGSize, bounds: CGSize) {
        let radians = angle * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let width = page.width * c + page.height * s
        let height = page.width * s + page.height * c
        guard width > 0, height > 0 else { return (.zero, .zero) }
        let k = min(box.width / width, box.height / height)
        return (CGSize(width: page.width * k, height: page.height * k), CGSize(width: width * k, height: height * k))
    }

    /// Fixed-size slots in rows: the Organize grid (four columns) and the Merge list (one).
    struct GridMetrics {
        var columns: Int
        var cell: CGSize
        var spacing: CGSize
        /// Space before the first slot, leading and top. Trailing and bottom match.
        var inset: CGPoint = .zero

        var pitch: CGSize {
            CGSize(width: cell.width + spacing.width, height: cell.height + spacing.height)
        }

        func origin(of index: Int) -> CGPoint {
            CGPoint(x: inset.x + CGFloat(index % columns) * pitch.width,
                    y: inset.y + CGFloat(index / columns) * pitch.height)
        }

        func frame(of index: Int) -> CGRect {
            CGRect(origin: origin(of: index), size: cell)
        }

        /// The slot under `point`, or nil over a gap or past the last slot.
        func slot(at point: CGPoint, count: Int) -> Int? {
            let x = point.x - inset.x, y = point.y - inset.y
            guard x >= 0, y >= 0 else { return nil }
            let column = Int(x / pitch.width), row = Int(y / pitch.height)
            guard column < columns,
                  x - CGFloat(column) * pitch.width <= cell.width,
                  y - CGFloat(row) * pitch.height <= cell.height else { return nil }
            let index = row * columns + column
            return index < count ? index : nil
        }

        /// The slot whose center is nearest `point`, clamped to the slots that exist.
        func nearest(to point: CGPoint, count: Int) -> Int {
            guard count > 0 else { return 0 }
            let column = Int(((point.x - inset.x - cell.width / 2) / pitch.width).rounded())
            let row = Int(((point.y - inset.y - cell.height / 2) / pitch.height).rounded())
            let index = max(0, row) * columns + min(max(0, column), columns - 1)
            return min(index, count - 1)
        }

        /// Height of `count` slots, insets included.
        func height(count: Int) -> CGFloat {
            let rows = (count + columns - 1) / columns
            guard rows > 0 else { return inset.y * 2 }
            return inset.y * 2 + CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing.height
        }
    }

    /// `items` with the ones in `ids` lifted out and put back together, starting at `start`.
    static func moving<Item: Identifiable>(_ items: [Item], _ ids: Set<Item.ID>, to start: Int) -> [Item] {
        let block = items.filter { ids.contains($0.id) }
        var rest = items.filter { !ids.contains($0.id) }
        rest.insert(contentsOf: block, at: min(max(0, start), rest.count))
        return rest
    }

    // MARK: - Scrolling

    struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var viewport: CGFloat = 0
        var content: CGFloat = 0
        var maxOffset: CGFloat { max(0, content - viewport) }
    }

    /// Scrolls a list while a dragged item is held near its top or bottom edge.
    @MainActor
    final class AutoScroller {
        private var timer: Timer?

        func start(_ tick: @escaping () -> Void) {
            stop()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// Points per frame: none away from the edges, faster the closer the pointer gets (or past them).
        static func speed(pointer y: CGFloat, viewport: CGFloat, edge: CGFloat = 36, fastest: CGFloat = 14) -> CGFloat {
            guard viewport > edge * 2 else { return 0 }
            if y < edge { return -fastest * min(1, (edge - y) / edge) }
            if y > viewport - edge { return fastest * min(1, (y - (viewport - edge)) / edge) }
            return 0
        }
    }

    // MARK: - Window

    /// Hands over the window a view lives in.
    struct WindowReader: NSViewRepresentable {
        var onWindow: (NSWindow) -> Void

        func makeNSView(context: Context) -> Probe {
            Probe(onWindow: onWindow)
        }

        func updateNSView(_ view: Probe, context: Context) {
            view.onWindow = onWindow
        }

        final class Probe: NSView {
            var onWindow: (NSWindow) -> Void

            init(onWindow: @escaping (NSWindow) -> Void) {
                self.onWindow = onWindow
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) is not used")
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { onWindow(window) }
            }
        }
    }

    /// Ties a tool to its window. Tool windows move when dragged by their background; over a list
    /// you reorder by dragging, the drag has to move the item instead, so that pauses while the
    /// pointer is there. Also routes key presses, and cleans up when the window closes.
    @MainActor
    final class WindowLink {
        private(set) weak var window: NSWindow?
        private var movable = true
        private var keyMonitor: Any?
        private var closeObserver: NSObjectProtocol?
        private var onClose: [() -> Void] = []

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            movable = window.isMovableByWindowBackground
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            }
        }

        func pointerOverReorderArea(_ inside: Bool) {
            window?.isMovableByWindowBackground = inside ? false : movable
        }

        /// Key presses while this window is key. The handler returns true when it used the key.
        func handleKeys(_ handler: @escaping (NSEvent) -> Bool) {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let window = self?.window, event.window === window, window.isKeyWindow else { return false }
                    return handler(event)
                }
                return handled ? nil : event
            }
        }

        func whenClosed(_ action: @escaping () -> Void) {
            onClose.append(action)
        }

        func detach() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            window?.isMovableByWindowBackground = movable
            let actions = onClose
            onClose = []
            actions.forEach { $0() }
        }
    }

    // MARK: - Small views

    /// A page image that loads in the background, with a grey placeholder until it arrives.
    struct Thumbnail: View {
        let reader: Reader
        let page: Int
        let pixels: CGSize
        @State private var image: CGImage?

        init(reader: Reader, page: Int, pixels: CGSize) {
            self.reader = reader
            self.page = page
            self.pixels = pixels
            // Pages already drawn show straight away when scrolled back into view: no flash.
            _image = State(initialValue: reader.cachedThumbnail(page))
        }

        var body: some View {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .transition(.opacity)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.07))
                }
            }
            .task(id: page) {
                guard image == nil else { return }
                guard let drawn = await reader.thumbnail(page, fitting: pixels) else { return }
                withAnimation(.easeOut(duration: 0.16)) { image = drawn }
            }
        }
    }
}
