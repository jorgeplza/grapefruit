import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Add BG: puts the photo on a gradient, a colour or a blurred image, with padding, rounded corners
/// and a soft shadow, like the original. The preview is drawn by the same code that saves the file.
struct AddBackgroundTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: BackgroundModel
    @State private var window: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _model = StateObject(wrappedValue: BackgroundModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: 440, onClose: session.close) {
            VStack(spacing: 0) {
                well
                    .frame(height: 334)
                backdropRows
                    .padding(.top, 17)
                sliders
                    .padding(.top, 9)
                ratioRow
            }
            .background(PhotoToolKit.WindowReader { found in
                DispatchQueue.main.async { window = found }
            })
        } footer: {
            ToolFooter(resetEnabled: model.canReset, onReset: reset,
                       primaryTitle: "Save with Background", primaryEnabled: model.canSave, onPrimary: save)
        }
        .onAppear { model.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in model.reduceMotion = value }
        .onDisappear { PhotoToolKit.ColorPanelLink.shared.release(owner: model) }
    }

    // MARK: Preview

    private var well: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 12, dy: 12)
            let fit = PhotoToolKit.Fit(pixels: model.rendered?.canvas ?? model.expectedCanvas, in: area)
            ZStack {
                if model.failed {
                    PhotoToolKit.LoadFailure(name: session.url.lastPathComponent, dark: false)
                } else if let rendered = model.rendered {
                    Image(decorative: rendered.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .clipped()
                        .id(rendered.key)
                        .transition(.opacity)
                        .position(x: fit.rect.midX, y: fit.rect.midY)
                } else {
                    PhotoToolKit.LoadingTile(dark: false)
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .position(x: fit.rect.midX, y: fit.rect.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .bottom) {
                if let message = model.message {
                    PhotoToolKit.GlassPill { Text(message) }
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ToolStyle.previewBackground))
        .accessibilityElement()
        .accessibilityLabel("Preview")
    }

    // MARK: Background

    private var backdropRows: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Background")
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: 89, height: 28, alignment: .leading)
            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    SwatchStrip {
                        ForEach(PhotoToolKit.Backdrops.meshes.indices, id: \.self) { index in
                            Swatch(selected: model.look.backdrop == .mesh(index), help: "Gradient \(index + 1)") {
                                choose(.mesh(index))
                            } fill: {
                                if let thumb = model.meshThumbs[index] {
                                    Image(decorative: thumb, scale: 2).resizable()
                                } else {
                                    Color.primary.opacity(0.06)
                                }
                            }
                        }
                    }
                    pictureButton
                        .frame(width: 44)
                }
                HStack(spacing: 8) {
                    SwatchStrip {
                        ForEach(PhotoToolKit.Backdrops.solids, id: \.self) { color in
                            Swatch(selected: model.look.backdrop == .solid(color), help: "Solid color") {
                                choose(.solid(color))
                            } fill: {
                                color.color
                            }
                        }
                    }
                    colorWell
                        .frame(width: 44)
                }
            }
        }
        .disabled(!model.canEdit)
    }

    private var pictureButton: some View {
        let selected = model.look.backdrop == .picture
        return Button {
            if model.picture != nil, !selected {
                choose(.picture)
            } else {
                pickPicture()
            }
        } label: {
            ZStack {
                if let picture = model.picture {
                    Image(decorative: picture.thumb, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.07)
                    Image(systemName: "photo.badge.plus.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                if model.loadingPicture {
                    Color.black.opacity(0.25)
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .overlay { SelectionRing(selected: selected, corner: 7) }
        }
        .buttonStyle(SwatchPress())
        .help(model.picture == nil ? "Use your own image" : (selected ? "Choose another image" : "Use your image"))
    }

    private var colorWell: some View {
        PhotoToolKit.ColorWell(color: model.look.custom, selected: model.look.backdrop == .custom) {
            choose(.custom)
            model.openColorPanel()
        }
        .help("Pick any color")
    }

    private func choose(_ backdrop: PhotoToolKit.Backdrops.Backdrop) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.22, bounce: 0.25)) {
            model.look.backdrop = backdrop
        }
    }

    private func pickPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        panel.message = "Choose an image for the background"
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.loadPicture(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 0) {
            SettingSlider(title: "Padding", value: $model.look.padding, range: 0...model.limits.padding)
            SettingSlider(title: "Corners", value: $model.look.corners, range: 0...model.limits.corners)
            SettingSlider(title: "Shadow", value: $model.look.shadow, range: 0...model.limits.shadow)
        }
        .disabled(!model.canEdit)
    }

    private var ratioRow: some View {
        HStack(spacing: 10) {
            Text("Ratio")
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
            Spacer(minLength: 8)
            Picker("Ratio", selection: $model.look.ratio) {
                ForEach(PhotoToolKit.Backdrops.Ratio.allCases) { ratio in
                    Text(ratio.title).tag(ratio)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 172)
        }
        .frame(height: 30)
        .disabled(!model.canEdit)
    }

    // MARK: Footer

    private func reset() {
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) { model.reset() }
    }

    private func save() {
        let look = model.look
        let picture = model.picture?.blurred
        let reference = model.info?.pixelSize
        session.runEach(ext: { PhotoToolKit.outputExtension(for: $0) }) { src, out, ctx in
            try PhotoToolKit.Backdrops.export(src, look: look, reference: reference, picture: picture,
                                              format: PhotoToolKit.outputFormat(for: src), to: out, ctx: ctx)
        }
    }
}

// MARK: - Pieces

/// "Padding ——o—— 160 px" with the label in grey, like the original.
private struct SettingSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(ToolStyle.label)
                .foregroundStyle(ToolStyle.secondary)
                .frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range)
            Text("\(Int(value.rounded())) px")
                .font(ToolStyle.mono)
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 27)
    }
}

/// A row of swatches that scrolls sideways, fading at whichever edge has more.
private struct SwatchStrip<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var more: [Bool] = [false, true]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6.75) { content }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .frame(height: 32)
        .onScrollGeometryChange(for: [Bool].self) { geo in
            [geo.contentOffset.x > 1, geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - 1]
        } action: { _, value in
            withAnimation(.easeOut(duration: 0.15)) { more = value }
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: more[0] ? 16 : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: more[1] ? 16 : 0)
            }
        }
        .padding(.vertical, -3)
    }
}

private struct Swatch<Fill: View>: View {
    var selected: Bool
    var help: String
    var action: () -> Void
    @ViewBuilder var fill: Fill

    var body: some View {
        Button(action: action) {
            fill
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .overlay { SelectionRing(selected: selected, corner: 6.5) }
        }
        .buttonStyle(SwatchPress())
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The orange ring on the chosen swatch. It settles in from slightly larger.
private struct SelectionRing: View {
    var selected: Bool
    /// nil draws a capsule.
    var corner: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if selected {
                Group {
                    if let corner {
                        RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ToolStyle.orange, lineWidth: 2)
                    } else {
                        Capsule().strokeBorder(ToolStyle.orange, lineWidth: 2)
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 1.18).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Grows a touch on hover and dips when pressed.
private struct SwatchPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hover(pressed: configuration.isPressed) { configuration.label }
    }

    private struct Hover<Label: View>: View {
        var pressed: Bool
        @ViewBuilder var label: Label
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .scaleEffect(pressed ? 0.92 : (hovering && isEnabled ? 1.06 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(duration: 0.2, bounce: 0.35), value: pressed)
                .animation(.spring(duration: 0.22, bounce: 0.3), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Model

@MainActor
private final class BackgroundModel: ObservableObject {
    typealias Look = PhotoToolKit.Backdrops.Look

    struct Rendered {
        let image: CGImage
        let canvas: CGSize
        /// Changes when the background itself changes, so the preview crossfades instead of cutting.
        let key: String
        let ratio: PhotoToolKit.Backdrops.Ratio
    }

    struct Picture {
        let blurred: CGImage
        let thumb: CGImage
        let id: Int
    }

    let url: URL
    let info: PhotoToolKit.SourceInfo?
    let defaults: Look
    let limits: (padding: Double, corners: Double, shadow: Double)
    @Published var look: Look {
        didSet { if look != oldValue { render() } }
    }
    @Published private(set) var rendered: Rendered?
    @Published private(set) var failed: Bool
    @Published private(set) var meshThumbs: [CGImage?] = Array(repeating: nil, count: PhotoToolKit.Backdrops.meshes.count)
    @Published private(set) var picture: Picture?
    @Published private(set) var loadingPicture = false
    @Published private(set) var message: String?
    var reduceMotion = false

    private var proxy: CGImage?
    private let worker = PhotoToolKit.LatestOnly("background")
    private var requested = 0
    private var shown = 0
    private var pictureCount = 0
    private var messageTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        let info = PhotoToolKit.sourceInfo(url)
        self.info = info
        failed = info == nil
        let size = info?.pixelSize ?? CGSize(width: 1600, height: 1200)
        defaults = PhotoToolKit.Backdrops.defaults(for: size)
        limits = PhotoToolKit.Backdrops.limits(for: size)
        look = defaults
        DispatchQueue.global(qos: .userInitiated).async {
            let thumbs = PhotoToolKit.Backdrops.meshes.map { PhotoToolKit.Backdrops.meshImage($0, width: 52, height: 52) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.meshThumbs = thumbs }
            }
        }
        guard info != nil else { return }
        PhotoToolKit.loadProxy(url, maxSide: 1400) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.failed = true
                return
            }
            self.proxy = image
            self.render()
        }
    }

    var canEdit: Bool { info != nil && !failed }
    var canSave: Bool { canEdit }
    /// The colour well keeps its colour through a reset, so it doesn't count as a change on its own.
    var canReset: Bool {
        var compared = look
        compared.custom = defaults.custom
        return canEdit && compared != defaults
    }

    /// The canvas shape before the first render arrives, so the placeholder already has it.
    var expectedCanvas: CGSize {
        PhotoToolKit.Backdrops.layout(photo: info?.pixelSize ?? CGSize(width: 4, height: 3), look: look).canvas
    }

    func reset() {
        var next = defaults
        next.custom = look.custom
        look = next
    }

    private func render() {
        guard let info, let proxy else { return }
        requested += 1
        let ticket = requested
        let look = self.look
        let picture = self.picture
        let photoSize = info.pixelSize
        let key = Self.key(look.backdrop, picture: picture)
        worker.submit { [weak self] in
            let canvas = PhotoToolKit.Backdrops.layout(photo: photoSize, look: look).canvas
            // Retina-sharp inside the 392 × 310 pt preview, small photos included.
            let scale = min(800 / canvas.width, 640 / canvas.height)
            let image = PhotoToolKit.Backdrops.render(photo: proxy, photoSize: photoSize, look: look,
                                                      picture: picture?.blurred, scale: scale,
                                                      space: PhotoToolKit.rgbSpace(of: proxy), deep: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let image, ticket > self.shown else { return }
                    self.shown = ticket
                    self.publish(Rendered(image: image, canvas: canvas, key: key, ratio: look.ratio))
                }
            }
        }
    }

    private func publish(_ next: Rendered) {
        let animate = rendered.map { $0.key != next.key || $0.ratio != next.ratio } ?? true
        if animate {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.08)) { rendered = next }
        } else {
            rendered = next
        }
    }

    private static func key(_ backdrop: PhotoToolKit.Backdrops.Backdrop, picture: Picture?) -> String {
        switch backdrop {
        case .mesh(let index): "mesh\(index)"
        case .solid(let color): "solid\(color.r)-\(color.g)-\(color.b)"
        // Dragging around the colour panel updates live instead of crossfading.
        case .custom: "custom"
        case .picture: "picture\(picture?.id ?? 0)"
        }
    }

    // MARK: Your own image

    func loadPicture(_ url: URL) {
        loadingPicture = true
        DispatchQueue.global(qos: .userInitiated).async {
            let small = PhotoToolKit.proxy(url, maxSide: 640)
            let blurred = small.flatMap { PhotoToolKit.Backdrops.blurred($0) }
            let thumb = small.map { PhotoToolKit.scaled($0, to: Self.thumbSize(for: $0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.loadingPicture = false
                    guard let blurred, let thumb else {
                        self.show("Couldn't open that image")
                        return
                    }
                    self.pictureCount += 1
                    self.picture = Picture(blurred: blurred, thumb: thumb, id: self.pictureCount)
                    if self.look.backdrop == .picture {
                        self.render()
                    } else {
                        withAnimation(.spring(duration: 0.22, bounce: 0.25)) { self.look.backdrop = .picture }
                    }
                }
            }
        }
    }

    nonisolated private static func thumbSize(for image: CGImage) -> CGSize {
        let s = 56 / CGFloat(max(1, min(image.width, image.height)))
        return CGSize(width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
    }

    private func show(_ text: String) {
        messageTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { message = text }
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.message = nil }
        }
    }

    // MARK: Colour panel

    func openColorPanel() {
        PhotoToolKit.ColorPanelLink.shared.open(with: look.custom, owner: self) { [weak self] color in
            guard let self else { return }
            var next = self.look
            next.custom = color
            next.backdrop = .custom
            self.look = next
        }
    }
}

// MARK: - Engine

extension PhotoToolKit {
    enum Backdrops {
        enum Backdrop: Hashable, Sendable {
            case mesh(Int)
            case solid(RGBA)
            /// The colour from the colour well, kept in the model.
            case custom
            case picture
        }

        enum Ratio: String, CaseIterable, Identifiable, Sendable {
            case auto, square, wide, portrait
            var id: Self { self }
            var title: String {
                switch self {
                case .auto: "Auto"
                case .square: "1:1"
                case .wide: "16:9"
                case .portrait: "4:5"
                }
            }
            /// Width over height; nil hugs the photo.
            var value: CGFloat? {
                switch self {
                case .auto: nil
                case .square: 1
                case .wide: 16 / 9
                case .portrait: 4 / 5
                }
            }
        }

        /// Sizes are in pixels of the original photo.
        struct Look: Equatable, Sendable {
            var backdrop: Backdrop = .mesh(0)
            var padding: Double
            var corners: Double
            var shadow: Double
            var ratio: Ratio = .auto
            /// Only used when `backdrop` is `.custom`.
            var custom = RGBA(hex: 0x416AC0)
        }

        /// A soft mesh gradient: colours on a grid, blended with smooth curves and a gentle wave.
        struct Mesh: Sendable {
            var cols: Int
            var rows: Int
            var colors: [UInt32]
            var xs: [Float]
            var ys: [Float]

            init(_ cols: Int, _ rows: Int, _ colors: [UInt32], xs: [Float]? = nil, ys: [Float]? = nil) {
                self.cols = cols
                self.rows = rows
                self.colors = colors
                self.xs = xs ?? [0.17, 0.5, 0.83]
                self.ys = ys ?? [0.17, 0.5, 0.83]
            }
        }

        /// Sampled from the original's swatches; the last three are extra.
        static let meshes: [Mesh] = [
            Mesh(5, 3, [0xEF8E97, 0xF09F79, 0xF2B070, 0xF3CB59, 0xF2B744,
                        0xED7364, 0xEE8960, 0xEA9F5B, 0xF1BE55, 0xEAB74F,
                        0xF2AC86, 0xE9866E, 0xBC698E, 0x856ACE, 0x8F5DB8],
                 xs: [0.04, 0.27, 0.5, 0.73, 0.96], ys: [0.045, 0.5, 0.955]),
            Mesh(3, 3, [0x91B2F7, 0xCEAAD0, 0xF3B67D, 0xE8EEFC, 0xFEFDFB, 0xFDF8F0, 0xFFFFFD, 0xFFFFFF, 0xFFFFFF]),
            Mesh(3, 3, [0xE6FEB4, 0xC9D1D8, 0xCC98EF, 0xE7C78C, 0xECF498, 0xBECFCF, 0xE47751, 0xFBF589, 0xB3E3CA]),
            Mesh(3, 3, [0xECC6C7, 0xD5B2C5, 0xCBBAE6, 0xF7DEDB, 0xE9CCD6, 0xE5DBEF, 0xFDFCFA, 0xFDFCFA, 0xFDFDFE]),
            Mesh(3, 3, [0xCEA7E3, 0xDCA5A8, 0xC79CC7, 0xDFB8CA, 0xE6C3C9, 0xDDB3CB, 0xEBCABD, 0xF8D4E2, 0xEDB1DA]),
            Mesh(3, 3, [0x41776D, 0x907971, 0xD95671, 0x2B585B, 0x76735D, 0xCF6875, 0xB49777, 0xEEB776, 0xB5CA87]),
            Mesh(3, 3, [0x85B1F5, 0x93B4F5, 0x86D5E7, 0x95C2F1, 0x81B0F9, 0x75BEEF, 0xC4ECE8, 0x9FC5F1, 0x6E9FF4]),
            Mesh(3, 3, [0x60AFDC, 0x73B9E7, 0x83C3EB, 0x77C4E2, 0x7CC8E7, 0x87DBEB, 0x5EC6DA, 0x86DDE9, 0x7BE6E8]),
            Mesh(3, 3, [0xC1C4F6, 0xA9B7F6, 0x8AA3F6, 0xEFE6F4, 0xF5E7F7, 0xF3EAFB, 0xF9E9F8, 0xF8EAF8, 0xF6EEF9]),
            // Dusk, Mint, Graphite.
            Mesh(3, 3, [0x1E2340, 0x3A2F6B, 0x6B3FA0, 0x2A2D5C, 0x7A4C9E, 0xD9677A, 0x4A3A7A, 0xE07F5F, 0xF4B26A]),
            Mesh(3, 3, [0xD7F5E3, 0xB8EBD3, 0xE8F7C8, 0xC2EEDC, 0xE6FAF0, 0xD3F2B9, 0xF4FBF6, 0xCFF1E1, 0xB5E6CF]),
            Mesh(3, 3, [0x4A5263, 0x363A44, 0x2A2C33, 0x3A3F4B, 0x2C2F37, 0x222429, 0x2C2F37, 0x212328, 0x18191D]),
        ]

        /// The original's solid row, then coral, sand and ink.
        static let solids: [RGBA] = [0xFAFBF8, 0xEECC5F, 0xADCF52, 0x5EA46F, 0x4F9C90, 0x76CCDF, 0x4562D5, 0x2B3B54,
                                     0x734FBF, 0xEC6A5E, 0xE6DCCB, 0x161616].map { RGBA(hex: $0) }

        static func defaults(for photo: CGSize) -> Look {
            let long = Double(max(photo.width, photo.height))
            return Look(padding: max(10, (long * 0.1 / 10).rounded() * 10),
                        corners: (long * 0.015).rounded(), shadow: (long * 0.015).rounded())
        }

        static func limits(for photo: CGSize) -> (padding: Double, corners: Double, shadow: Double) {
            let long = Double(max(photo.width, photo.height)), short = Double(min(photo.width, photo.height))
            return (max(40, (long * 0.75).rounded()), max(4, (short * 0.25).rounded()), max(4, (long * 0.08).rounded()))
        }

        /// Canvas size and where the photo sits (bottom-left origin), in original pixels.
        static func layout(photo: CGSize, look: Look) -> (canvas: CGSize, photo: CGRect) {
            let pad = CGFloat(max(0, look.padding.rounded()))
            let content = CGSize(width: photo.width + pad * 2, height: photo.height + pad * 2)
            var canvas = content
            if let r = look.ratio.value {
                if content.width / content.height > r {
                    canvas.height = (content.width / r).rounded(.up)
                } else {
                    canvas.width = (content.height * r).rounded(.up)
                }
            }
            let x = ((canvas.width - photo.width) / 2).rounded(.down)
            let y = ((canvas.height - photo.height) / 2).rounded(.down)
            return (canvas, CGRect(x: x, y: y, width: photo.width, height: photo.height))
        }

        // MARK: Drawing

        /// Draws the whole picture. `photo` may be a smaller copy; `photoSize` is the original's size and
        /// sets the layout, and `scale` shrinks everything for the preview.
        static func render(photo: CGImage, photoSize: CGSize, look: Look, picture: CGImage?, scale: CGFloat,
                           space: CGColorSpace, deep: Bool) -> CGImage? {
            let (canvas, place) = layout(photo: photoSize, look: look)
            let width = max(1, Int((canvas.width * scale).rounded()))
            let height = max(1, Int((canvas.height * scale).rounded()))
            let sx = CGFloat(width) / canvas.width, sy = CGFloat(height) / canvas.height
            let s = (sx + sy) / 2
            let photoRect = CGRect(x: place.minX * sx, y: place.minY * sy, width: place.width * sx, height: place.height * sy)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                    ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: PhotoToolKit.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return nil
            }
            ctx.interpolationQuality = .high
            let full = CGRect(x: 0, y: 0, width: width, height: height)

            switch look.backdrop {
            case .solid(let color):
                ctx.setFillColor(color.cgColor)
                ctx.fill(full)
            case .custom:
                ctx.setFillColor(look.custom.cgColor)
                ctx.fill(full)
            case .mesh(let index):
                if let base = meshBase(index) {
                    ctx.draw(base, in: full)
                } else {
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(full)
                }
            case .picture:
                if let picture {
                    // Fill the canvas, cropping the overflow.
                    let iw = CGFloat(picture.width), ih = CGFloat(picture.height)
                    let k = max(CGFloat(width) / iw, CGFloat(height) / ih)
                    ctx.draw(picture, in: CGRect(x: (CGFloat(width) - iw * k) / 2, y: (CGFloat(height) - ih * k) / 2,
                                                 width: iw * k, height: ih * k))
                } else {
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(full)
                }
            }

            let radius = min(CGFloat(max(0, look.corners.rounded())) * s, min(photoRect.width, photoRect.height) / 2)
            let path = CGPath(roundedRect: photoRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let blur = CGFloat(max(0, look.shadow.rounded())) * s
            let transparent = PhotoToolKit.hasAlpha(photo)

            if blur > 0.05 {
                ctx.saveGState()
                // A soft drop shadow, a little below the photo.
                ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.3), blur: blur,
                              color: CGColor(gray: 0, alpha: 0.35))
                if transparent {
                    // The shadow follows the photo's own outline.
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    ctx.addPath(path)
                    ctx.clip()
                    ctx.draw(photo, in: photoRect)
                    ctx.endTransparencyLayer()
                } else {
                    // Cast from a shape a hair inside the photo, so no dark edge peeks out.
                    let inset = min(1, photoRect.width / 4, photoRect.height / 4)
                    ctx.addPath(CGPath(roundedRect: photoRect.insetBy(dx: inset, dy: inset),
                                       cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset), transform: nil))
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
            if !(transparent && blur > 0.05) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.draw(photo, in: photoRect)
                ctx.restoreGState()
            }
            return ctx.makeImage()
        }

        /// A small square of the gradient, stretched over any canvas. Cached; the gradients never change.
        static func meshBase(_ index: Int) -> CGImage? {
            guard meshes.indices.contains(index) else { return nil }
            if let cached = baseCache.get(index) { return cached }
            let image = meshImage(meshes[index], width: 256, height: 256)
            if let image { baseCache.set(index, image) }
            return image
        }

        private static let baseCache = ImageCache()

        private final class ImageCache: @unchecked Sendable {
            private let lock = NSLock()
            private var images: [Int: CGImage] = [:]
            func get(_ key: Int) -> CGImage? { lock.withLock { images[key] } }
            func set(_ key: Int, _ image: CGImage) { lock.withLock { images[key] = image } }
        }

        static func meshImage(_ mesh: Mesh, width: Int, height: Int) -> CGImage? {
            guard mesh.cols >= 2, mesh.rows >= 2, mesh.colors.count == mesh.cols * mesh.rows else { return nil }
            let colors = mesh.colors.map {
                SIMD3<Float>(Float(($0 >> 16) & 0xFF), Float(($0 >> 8) & 0xFF), Float($0 & 0xFF))
            }
            func segment(_ p: Float, _ stops: [Float]) -> (Int, Float) {
                if p <= stops[0] { return (0, 0) }
                if p >= stops[stops.count - 1] { return (stops.count - 2, 1) }
                var k = 0
                while k < stops.count - 2, p >= stops[k + 1] { k += 1 }
                let t = (p - stops[k]) / (stops[k + 1] - stops[k])
                return (k, t * t * (3 - 2 * t))
            }
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                let v0 = (Float(y) + 0.5) / Float(height)
                for x in 0..<width {
                    let u0 = (Float(x) + 0.5) / Float(width)
                    // A gentle wave so the blend flows instead of following the grid.
                    let u = u0 + 0.035 * sin((v0 * 1.7 + 0.15) * 2 * .pi)
                    let v = v0 + 0.035 * sin((u0 * 1.3 + 0.6) * 2 * .pi)
                    let (i, tx) = segment(u, mesh.xs)
                    let (j, ty) = segment(v, mesh.ys)
                    let a = colors[j * mesh.cols + i], b = colors[j * mesh.cols + i + 1]
                    let c = colors[(j + 1) * mesh.cols + i], d = colors[(j + 1) * mesh.cols + i + 1]
                    let top = a + (b - a) * tx, bottom = c + (d - c) * tx
                    let px = top + (bottom - top) * ty
                    let o = (y * width + x) * 4
                    bytes[o] = UInt8(min(max(px.x.rounded(), 0), 255))
                    bytes[o + 1] = UInt8(min(max(px.y.rounded(), 0), 255))
                    bytes[o + 2] = UInt8(min(max(px.z.rounded(), 0), 255))
                }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: PhotoToolKit.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        /// Your own image, softly blurred. Small on purpose: it's stretched over the canvas.
        static func blurred(_ picture: CGImage) -> CGImage? {
            let input = CIImage(cgImage: picture)
            let extent = input.extent
            let radius = max(extent.width, extent.height) * 0.03
            let output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            return PhotoToolKit.makeImage(output, extent: extent, space: PhotoToolKit.sRGB)
        }

        // MARK: Saving

        /// Biggest canvas we write; larger ones are scaled down to fit.
        static let maxPixels: CGFloat = 120_000_000
        static let maxSide: CGFloat = 20_000

        /// The same look on a photo of another size: padding, corners and shadow keep their share of the long edge.
        static func look(_ look: Look, from reference: CGSize, to size: CGSize) -> Look {
            let k = Double(max(size.width, size.height) / max(1, max(reference.width, reference.height)))
            guard abs(k - 1) > 0.001 else { return look }
            var next = look
            next.padding = (look.padding * k).rounded()
            next.corners = (look.corners * k).rounded()
            next.shadow = (look.shadow * k).rounded()
            return next
        }

        /// `reference` is the size the look was set on; other photos in a batch get it scaled to fit them.
        static func export(_ src: URL, look: Look, reference: CGSize? = nil, picture: CGImage?, format: String,
                           to out: URL, ctx: JobContext) throws {
            ctx.progress(0.05)
            let loaded = try ImageEngine.load(src)
            try ctx.checkCancelled()
            ctx.progress(0.35)
            let photo = loaded.image
            let size = CGSize(width: photo.width, height: photo.height)
            let look = reference.map { Self.look(look, from: $0, to: size) } ?? look
            let canvas = layout(photo: size, look: look).canvas
            let scale = min(1, (maxPixels / (canvas.width * canvas.height)).squareRoot(), maxSide / max(canvas.width, canvas.height))
            guard let image = render(photo: photo, photoSize: size, look: look, picture: picture, scale: scale,
                                     space: PhotoToolKit.rgbSpace(of: photo), deep: photo.bitsPerComponent > 8) else {
                throw JobError.failed("Couldn't draw the background.")
            }
            try ctx.checkCancelled()
            ctx.progress(0.75)
            try PhotoToolKit.save(image, metadata: loaded.properties, format: format, to: out, ctx: ctx)
            ctx.progress(1)
        }
    }
}
