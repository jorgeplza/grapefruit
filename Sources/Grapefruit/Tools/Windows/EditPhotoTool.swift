import CoreImage
import SwiftUI

/// Edit Photo: a large preview over Light, Color, Detail and Effects sliders, like the original.
/// The preview renders a downscaled copy on the GPU; saving renders the full photo with the same recipe.
struct EditPhotoTool: View {
    static let isReady = true
    @ObservedObject var session: ToolSession
    @StateObject private var model: EditModel
    @State private var showOriginal = false
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var pinch: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: ToolSession) {
        _session = ObservedObject(wrappedValue: session)
        _model = StateObject(wrappedValue: EditModel(url: session.url))
    }

    var body: some View {
        ToolChrome(title: session.tool.name, width: 480, onClose: session.close) {
            VStack(spacing: 0) {
                preview
                    .frame(height: 290)
                sliders
            }
        } footer: {
            ToolFooter(showsReset: false, primaryTitle: session.urls.count > 1 ? "Save Edited Copies" : "Save Edited Copy",
                       primaryEnabled: model.canSave, onPrimary: save)
        }
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let well = geo.size
            let pixels = model.info?.pixelSize ?? CGSize(width: 3, height: 2)
            let fit = PhotoToolKit.Fit(pixels: pixels, in: CGRect(origin: .zero, size: well).insetBy(dx: 8, dy: 8))
            ZStack {
                PhotoToolKit.Look.darkWell
                if model.failed {
                    PhotoToolKit.LoadFailure(name: session.url.lastPathComponent, dark: true)
                } else if let image = showOriginal ? model.original : (model.rendered ?? model.original) {
                    photo(image, fit: fit, well: well)
                        .transition(.opacity)
                } else {
                    PhotoToolKit.LoadingTile(dark: true)
                        .frame(width: fit.rect.width, height: fit.rect.height)
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.original != nil)
            .contentShape(Rectangle())
            .gesture(panGesture(fit: fit, well: well), including: model.zoomIndex > 0 ? .all : .none)
            .simultaneousGesture(pinchGesture(fit: fit, well: well), including: model.canEdit ? .all : .none)
            .onTapGesture(count: 2) { toggleZoom(fit: fit, well: well) }
            .pointerStyle(wellPointer)
            .overlay(alignment: .top) {
                if !model.failed { toolbar(fit: fit, well: well) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PhotoToolKit.Look.wellCorner, style: .continuous))
    }

    private var wellPointer: PointerStyle? {
        guard model.zoomIndex > 0 else { return nil }
        return panStart != nil ? .grabActive : .grabIdle
    }

    private func photo(_ image: CGImage, fit: PhotoToolKit.Fit, well: CGSize) -> some View {
        let zoom = effectiveZoom
        let size = CGSize(width: fit.rect.width * zoom, height: fit.rect.height * zoom)
        let offset = clamped(pan, size: size, well: well)
        return ZStack {
            if model.info?.hasAlpha == true { PhotoToolKit.Checkerboard(dark: true) }
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        }
        .frame(width: size.width, height: size.height)
        .offset(offset)
        .position(x: well.width / 2, y: well.height / 2)
        .allowsHitTesting(false)
    }

    private var effectiveZoom: CGFloat {
        min(max(model.zoom * pinch, 1), EditModel.zoomSteps.last ?? 4)
    }

    private func clamped(_ offset: CGSize, size: CGSize, well: CGSize) -> CGSize {
        let maxX = max(0, (size.width - well.width) / 2 + 8)
        let maxY = max(0, (size.height - well.height) / 2 + 8)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    private func panGesture(fit: PhotoToolKit.Fit, well: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = panStart ?? pan
                if panStart == nil { panStart = pan }
                pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in
                panStart = nil
                let size = CGSize(width: fit.rect.width * model.zoom, height: fit.rect.height * model.zoom)
                pan = clamped(pan, size: size, well: well)
            }
    }

    private func pinchGesture(fit: PhotoToolKit.Fit, well: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { pinch = $0.magnification }
            .onEnded { value in
                let target = model.zoom * value.magnification
                let steps = EditModel.zoomSteps
                let nearest = steps.indices.min { abs(steps[$0] - target) < abs(steps[$1] - target) } ?? 0
                withAnimation(PhotoToolKit.motion(reduceMotion)) {
                    pinch = 1
                    setZoom(nearest, fit: fit, well: well)
                }
            }
    }

    private func toggleZoom(fit: PhotoToolKit.Fit, well: CGSize) {
        guard model.canEdit else { return }
        let target = model.zoomIndex == 0 ? (EditModel.zoomSteps.firstIndex(of: 2) ?? 1) : 0
        withAnimation(PhotoToolKit.motion(reduceMotion)) { setZoom(target, fit: fit, well: well) }
    }

    /// Zooms around the middle of what's showing.
    private func setZoom(_ index: Int, fit: PhotoToolKit.Fit, well: CGSize) {
        let steps = EditModel.zoomSteps
        let index = min(max(index, 0), steps.count - 1)
        let ratio = steps[index] / model.zoom
        model.zoomIndex = index
        let size = CGSize(width: fit.rect.width * steps[index], height: fit.rect.height * steps[index])
        pan = index == 0 ? .zero : clamped(CGSize(width: pan.width * ratio, height: pan.height * ratio), size: size, well: well)
    }

    private func toolbar(fit: PhotoToolKit.Fit, well: CGSize) -> some View {
        HStack(spacing: 6) {
            WellButton(help: "Zoom out") {
                withAnimation(PhotoToolKit.motion(reduceMotion)) { setZoom(model.zoomIndex - 1, fit: fit, well: well) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(model.zoomIndex == 0 || !model.canEdit)

            Text("\(Int((model.zoom * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(model.canEdit ? 0.85 : 0.35))
                .frame(minWidth: 34)
                .contentTransition(.numericText())

            WellButton(help: "Zoom in") {
                withAnimation(PhotoToolKit.motion(reduceMotion)) { setZoom(model.zoomIndex + 1, fit: fit, well: well) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(model.zoomIndex == EditModel.zoomSteps.count - 1 || !model.canEdit)

            Spacer()

            WellButton(help: "Reset all sliders") {
                withAnimation(.snappy(duration: 0.22)) { model.adjustments = PhotoToolKit.Adjustments() }
            } label: {
                Text("Reset")
            }
            .disabled(model.adjustments.isIdentity)

            HoldButton(title: "Original", help: "Hold to see the original", pressing: $showOriginal)
                .disabled(model.adjustments.isIdentity || !model.canEdit)
        }
        .padding(8)
    }

    // MARK: Sliders

    private var sliders: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(EditSection.all.enumerated()), id: \.element.id) { index, section in
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ToolStyle.secondary)
                        .frame(height: 20)
                        .padding(.top, index == 0 ? 8 : 12)
                    ForEach(section.controls) { control in
                        AdjustRow(control: control, value: $model.adjustments[dynamicMember: control.key])
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .scrollIndicators(.automatic)
        .frame(height: 384)
        // Runs under the footer hairline like the original.
        .padding(.bottom, -ToolStyle.contentPadding)
        .disabled(model.failed)
        .opacity(model.failed ? 0.5 : 1)
    }

    // MARK: Save

    private func save() {
        let adjustments = model.adjustments
        session.runEach(ext: { PhotoToolKit.outputExtension(for: $0) }) { src, out, ctx in
            // Each file keeps its own transparency, so a batch can mix JPEGs and cut-out PNGs.
            let keepAlpha = PhotoToolKit.sourceInfo(src)?.hasAlpha ?? false
            try PhotoToolKit.PhotoEdits.export(src, adjustments: adjustments, format: PhotoToolKit.outputFormat(for: src),
                                               keepAlpha: keepAlpha, to: out, ctx: ctx)
        }
    }
}

// MARK: - Model

@MainActor
private final class EditModel: ObservableObject {
    static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4]
    /// The fit view never needs more than this; zooming in loads a sharper copy.
    private static let baseSide = 1400

    let url: URL
    let info: PhotoToolKit.SourceInfo?
    @Published var adjustments = PhotoToolKit.Adjustments() {
        didSet { if adjustments != oldValue { render() } }
    }
    @Published var zoomIndex = 0 {
        didSet { if zoomIndex != oldValue { zoomChanged() } }
    }
    @Published private(set) var rendered: CGImage?
    @Published private(set) var failed = false
    @Published private var base: CGImage?
    @Published private var detail: CGImage?
    private var loadingDetail = false
    private let worker = PhotoToolKit.LatestOnly("edit")
    private var requested = 0
    private var shown = 0

    init(url: URL) {
        self.url = url
        info = PhotoToolKit.sourceInfo(url)
        guard info != nil else {
            failed = true
            return
        }
        PhotoToolKit.loadProxy(url, maxSide: Self.baseSide) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.failed = true
                return
            }
            self.base = image
            self.render()
        }
    }

    var zoom: CGFloat { Self.zoomSteps[zoomIndex] }
    var canEdit: Bool { base != nil }
    var canSave: Bool { canEdit && !adjustments.isIdentity }

    /// The unedited picture at the current zoom, for "Original".
    var original: CGImage? { (zoom > 1.5 ? detail : nil) ?? base }

    func render() {
        guard let info, let source = original else { return }
        requested += 1
        let ticket = requested
        let adjustments = self.adjustments
        let longEdge = info.longEdge
        worker.submit { [weak self] in
            let image = PhotoToolKit.PhotoEdits.preview(adjustments, base: source, originalLongEdge: longEdge)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, ticket > self.shown else { return }
                    self.shown = ticket
                    if let image { self.rendered = image }
                }
            }
        }
    }

    private func zoomChanged() {
        if zoom > 1.5, detail == nil, !loadingDetail, let info, info.longEdge > CGFloat(Self.baseSide) {
            loadingDetail = true
            PhotoToolKit.loadProxy(url, maxSide: Int(min(info.longEdge, 4096))) { [weak self] image in
                guard let self else { return }
                self.detail = image
                self.render()
            }
        }
        render()
    }
}

// MARK: - Controls

private struct EditControl: Identifiable {
    enum Unit { case ev, signed, unsigned, degrees }

    let title: String
    let key: WritableKeyPath<PhotoToolKit.Adjustments, Double>
    let range: ClosedRange<Double>
    var unit: Unit = .signed
    var id: String { title }

    func format(_ value: Double) -> String {
        switch unit {
        case .ev:
            let v = (value * 100).rounded() / 100
            return v == 0 ? "0.00 EV" : String(format: "%+.2f EV", v)
        case .signed: return String(format: "%+ld", Int(value.rounded()))
        case .unsigned: return "\(Int(value.rounded()))"
        case .degrees: return "\(Int(value.rounded()))°"
        }
    }
}

private struct EditSection: Identifiable {
    let title: String
    let controls: [EditControl]
    var id: String { title }

    static let all: [EditSection] = [
        EditSection(title: "Light", controls: [
            EditControl(title: "Exposure", key: \.exposure, range: -3...3, unit: .ev),
            EditControl(title: "Brightness", key: \.brightness, range: -100...100),
            EditControl(title: "Contrast", key: \.contrast, range: -100...100),
            EditControl(title: "Highlights", key: \.highlights, range: -100...100),
            EditControl(title: "Shadows", key: \.shadows, range: -100...100),
            EditControl(title: "Whites", key: \.whites, range: -100...100),
            EditControl(title: "Blacks", key: \.blacks, range: -100...100),
            EditControl(title: "Gamma", key: \.gamma, range: -100...100),
        ]),
        EditSection(title: "Color", controls: [
            EditControl(title: "Temperature", key: \.temperature, range: -100...100),
            EditControl(title: "Tint", key: \.tint, range: -100...100),
            EditControl(title: "Saturation", key: \.saturation, range: -100...100),
            EditControl(title: "Vibrance", key: \.vibrance, range: -100...100),
            EditControl(title: "Hue", key: \.hue, range: -180...180, unit: .degrees),
        ]),
        EditSection(title: "Detail", controls: [
            EditControl(title: "Clarity", key: \.clarity, range: -100...100),
            EditControl(title: "Sharpness", key: \.sharpness, range: 0...100, unit: .unsigned),
            EditControl(title: "Noise Reduction", key: \.noiseReduction, range: 0...100, unit: .unsigned),
        ]),
        EditSection(title: "Effects", controls: [
            EditControl(title: "Vignette", key: \.vignette, range: 0...100, unit: .unsigned),
            EditControl(title: "Grain", key: \.grain, range: 0...100, unit: .unsigned),
            EditControl(title: "Fade", key: \.fade, range: 0...100, unit: .unsigned),
        ]),
    ]
}

/// "Exposure ——o—— 0.00 EV ↺"
private struct AdjustRow: View {
    let control: EditControl
    @Binding var value: Double

    var body: some View {
        let changed = value != 0
        HStack(spacing: 10) {
            Text(control.title)
                .font(ToolStyle.label)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            Slider(value: $value, in: control.range)
            Text(control.format(value))
                .font(ToolStyle.mono)
                .foregroundStyle(ToolStyle.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
            Button {
                withAnimation(.snappy(duration: 0.2)) { value = 0 }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(changed ? ToolStyle.secondary : Color.secondary.opacity(0.45))
            .disabled(!changed)
            .help("Reset \(control.title)")
        }
        .frame(height: 22)
    }
}

/// A glass capsule button that sits on the dark preview.
private struct WellButton<Label: View>: View {
    var help: String
    var action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? (hovering ? 1 : 0.86) : 0.32))
                .padding(.horizontal, 9)
                .frame(minWidth: 26, minHeight: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.black.opacity(0.32)).interactive(isEnabled), in: Capsule())
        .environment(\.colorScheme, .dark)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Shows the original while the pointer is held down.
private struct HoldButton: View {
    var title: String
    var help: String
    @Binding var pressing: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(isEnabled ? (hovering || pressing ? 1 : 0.86) : 0.32))
            .padding(.horizontal, 9)
            .frame(minWidth: 26, minHeight: 22)
            .contentShape(Capsule())
            .glassEffect(.regular.tint(Color.black.opacity(pressing ? 0.5 : 0.32)).interactive(isEnabled), in: Capsule())
            .environment(\.colorScheme, .dark)
            .onHover { hovering = $0 }
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 400, perform: {}, onPressingChanged: { down in
                pressing = down && isEnabled
            })
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { pressing = false }
            }
            .help(help)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Engine

extension PhotoToolKit {
    /// Every Edit Photo slider. Zero means untouched.
    struct Adjustments: Equatable, Sendable {
        // Light
        var exposure = 0.0
        var brightness = 0.0
        var contrast = 0.0
        var highlights = 0.0
        var shadows = 0.0
        var whites = 0.0
        var blacks = 0.0
        var gamma = 0.0
        // Color
        var temperature = 0.0
        var tint = 0.0
        var saturation = 0.0
        var vibrance = 0.0
        var hue = 0.0
        // Detail
        var clarity = 0.0
        var sharpness = 0.0
        var noiseReduction = 0.0
        // Effects
        var vignette = 0.0
        var grain = 0.0
        var fade = 0.0

        var isIdentity: Bool { self == Adjustments() }
        var hasTone: Bool {
            brightness != 0 || contrast != 0 || highlights != 0 || shadows != 0 || whites != 0
                || blacks != 0 || gamma != 0 || fade != 0
        }
    }

    /// The Core Image recipe behind Edit Photo. The same code renders the preview and the saved file.
    enum PhotoEdits {
        /// `detailScale` is the processed size over the original size, so pixel-level effects
        /// (sharpening) look the same in a small preview as in the full photo.
        static func apply(_ a: Adjustments, to input: CIImage, detailScale: CGFloat) -> CIImage {
            let extent = input.extent
            let longEdge = max(extent.width, extent.height)
            var image = input

            if a.exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
            }
            if a.temperature != 0 || a.tint != 0 {
                // Warmer means a lower target white point. Steps in mireds feel even across the range.
                let mired = 1_000_000 / 6500 + a.temperature / 100 * 60
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 1_000_000 / mired, y: -a.tint / 100 * 60),
                ])
            }
            if a.hasTone {
                image = image.applyingFilter("CIColorCurves", parameters: [
                    "inputCurvesData": toneCurve(a),
                    "inputCurvesDomain": CIVector(x: 0, y: 1),
                    "inputColorSpace": PhotoToolKit.sRGB,
                ])
            }
            if a.saturation != 0 {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 + a.saturation / 100, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
                ])
            }
            if a.vibrance != 0 {
                image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100])
            }
            if a.hue != 0 {
                image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180])
            }

            // Detail filters read past the edges, so they work on clamped copies.
            if a.noiseReduction > 0 {
                let n = a.noiseReduction / 100
                image = image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": 0.005 + n * 0.07, "inputSharpness": 0.4 * (1 - n * 0.6),
                ]).cropped(to: extent)
            }
            if a.clarity > 0 {
                image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: longEdge * 0.02, kCIInputIntensityKey: a.clarity / 100 * 0.6,
                ]).cropped(to: extent)
            } else if a.clarity < 0 {
                let soft = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: longEdge * 0.01])
                    .cropped(to: extent)
                image = image.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: soft, kCIInputTimeKey: -a.clarity / 100 * 0.5,
                ])
            }
            if a.sharpness > 0 {
                let fullRadius = max(1, longEdge / max(detailScale, 0.01) / 3000)
                image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: a.sharpness / 100 * 1.2, kCIInputRadiusKey: max(0.5, fullRadius * detailScale),
                ]).cropped(to: extent)
            }
            if a.vignette > 0, let mask = radialMask(in: extent) {
                let darker = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2.2 * a.vignette / 100])
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: darker, kCIInputMaskImageKey: mask,
                ])
            }
            if a.grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
                // Grey noise around mid grey, soft-lit onto the photo: strongest in the midtones like film.
                // It scales with the frame, so the preview shows the same texture as the saved photo,
                // and a light blur turns digital noise into softer grain.
                let g = a.grain / 100
                let size = max(1, longEdge / 1800)
                let spread = g * 0.5
                // The generator's alpha is random too; make it opaque first or the matrix divides by it.
                let source = CGRect(x: extent.minX / size - 4, y: extent.minY / size - 4,
                                    width: extent.width / size + 8, height: extent.height / size + 8)
                let layer = noise
                    .cropped(to: source)
                    .settingAlphaOne(in: source)
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: spread, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: spread, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: spread, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBiasVector": CIVector(x: 0.5 - spread / 2, y: 0.5 - spread / 2, z: 0.5 - spread / 2, w: 1),
                    ])
                    .transformed(by: CGAffineTransform(scaleX: size, y: size))
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.35, size * 0.45)])
                    .cropped(to: extent)
                let grained = layer.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                // Keep transparent pixels transparent.
                image = grained.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
            }
            return image.cropped(to: extent)
        }

        /// White in the middle, black at the corners.
        private static func radialMask(in extent: CGRect) -> CIImage? {
            let half = hypot(extent.width, extent.height) / 2
            return CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": half * 0.42, "inputRadius1": half * 1.04,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])?.outputImage?.cropped(to: extent)
        }

        /// One curve for every tone slider, applied in sRGB.
        static func toneCurve(_ a: Adjustments, samples: Int = 512) -> Data {
            let blacks = a.blacks / 100, whites = a.whites / 100
            let shadows = a.shadows / 100, highlights = a.highlights / 100
            let brightness = a.brightness / 100, contrast = a.contrast / 100, fade = a.fade / 100
            let power = pow(2, -a.gamma / 100)
            func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
            var values: [Float] = []
            values.reserveCapacity(samples * 3)
            for i in 0..<samples {
                var x = Double(i) / Double(samples - 1)
                x = clamp(x + blacks * 0.25 * pow(1 - x, 4))
                x = clamp(x + whites * 0.25 * pow(x, 4))
                x = clamp(x + shadows * x * (1 - x) * (1 - x))
                x = clamp(x + highlights * x * x * (1 - x))
                x = clamp(x + brightness * 0.6 * x * (1 - x))
                if power != 1 { x = pow(x, power) }
                if contrast > 0 {
                    x += contrast * 0.7 * (x * x * (3 - 2 * x) - x)
                } else if contrast < 0 {
                    let flat = 0.5 - sin(asin(1 - 2 * x) / 3)
                    x += -contrast * 0.7 * (flat - x)
                }
                x = clamp(x)
                if fade > 0 { x = fade * 0.12 + x * (1 - fade * 0.18) }
                let v = Float(x)
                values.append(contentsOf: [v, v, v])
            }
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        /// Renders the preview from a downscaled copy.
        static func preview(_ a: Adjustments, base: CGImage, originalLongEdge: CGFloat) -> CGImage? {
            if a.isIdentity { return base }
            let input = CIImage(cgImage: base)
            let scale = min(1, CGFloat(max(base.width, base.height)) / max(1, originalLongEdge))
            return PhotoToolKit.makeImage(apply(a, to: input, detailScale: scale), extent: input.extent,
                                          space: PhotoToolKit.rgbSpace(of: base))
        }

        /// Full resolution, same format, metadata kept. 16-bit sources stay 16-bit.
        static func export(_ src: URL, adjustments: Adjustments, format: String, keepAlpha: Bool,
                           to out: URL, ctx: JobContext) throws {
            ctx.progress(0.05)
            let loaded = try ImageEngine.load(src)
            try ctx.checkCancelled()
            ctx.progress(0.35)
            let input = CIImage(cgImage: loaded.image)
            let recipe = apply(adjustments, to: input, detailScale: 1)
            guard var image = PhotoToolKit.makeImage(recipe, extent: input.extent,
                                                     space: PhotoToolKit.rgbSpace(of: loaded.image),
                                                     deep: loaded.image.bitsPerComponent > 8) else {
                throw JobError.failed("Couldn't render the edited photo.")
            }
            try ctx.checkCancelled()
            ctx.progress(0.75)
            if !keepAlpha { image = PhotoToolKit.droppingAlpha(image) }
            try PhotoToolKit.save(image, metadata: loaded.properties, format: format, to: out, ctx: ctx)
            ctx.progress(1)
        }
    }
}
