import AppKit
import SwiftUI

/// Which tools are ready, and how each one starts.
@MainActor
enum ToolRegistry {
    /// Tools that open a window. A tool shows on the wheel only once it's built.
    static var windows: [ToolID: (ToolSession) -> AnyView] = ToolCatalog.windows

    static func isAvailable(_ tool: ToolID) -> Bool {
        if tool.runsInstantly { return true }
        guard windows[tool] != nil else { return false }
        // Audio and video tools need ffmpeg.
        switch tool {
        case .compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage,
             .organizePDF, .mergePDF, .createCollage, .redactImage:
            return true
        default:
            return Capabilities.hasFFmpeg
        }
    }

    static func open(_ tool: ToolID, urls: [URL], anchor: NSPoint) {
        if tool.runsInstantly {
            InstantTools.run(tool, urls: urls, anchor: anchor)
            return
        }
        guard let make = windows[tool] else { return }
        let session = ToolSession(tool: tool, urls: urls, anchor: anchor)
        ToolWindowController.present(session: session, content: make(session))
    }
}

/// What a tool window knows: the files, where the wheel was, and how to finish.
@MainActor
final class ToolSession: ObservableObject {
    let tool: ToolID
    let urls: [URL]
    let anchor: NSPoint
    var close: () -> Void = {}

    init(tool: ToolID, urls: [URL], anchor: NSPoint) {
        self.tool = tool
        self.urls = urls
        self.anchor = anchor
    }

    var url: URL { urls[0] }

    /// Close the window and run the work with a progress card where the wheel was.
    func run(_ steps: [JobStep], title: String? = nil) {
        close()
        JobCenter.shared.run(title: title ?? tool.progressVerb, steps: steps, anchor: anchor)
    }

    /// One step per file, each writing "name Suffix.ext" next to the original.
    func runEach(ext: ((URL) -> String)? = nil, title: String? = nil,
                 _ work: @escaping (URL, URL, JobContext) throws -> Void) {
        let suffix = tool.outputSuffix
        let steps = urls.map { src in
            JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
                let out = ctx.output(Output.name(src, suffix: suffix, ext: ext?(src)))
                try work(src, out, ctx)
                return [out]
            }
        }
        run(steps, title: title)
    }
}

// MARK: - Instant tools

@MainActor
enum InstantTools {
    static func run(_ tool: ToolID, urls: [URL], anchor: NSPoint) {
        switch tool {
        case .muteVideo:
            let steps = urls.map { src in
                JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
                    let info = try MediaEngine.probe(src, ctx: ctx)
                    let out = ctx.output(Output.name(src, suffix: tool.outputSuffix))
                    var args = ["-i", src.path, "-map", "0", "-map", "-0:a", "-c", "copy", "-map_metadata", "0"]
                    if ["mp4", "mov", "m4v"].contains(src.pathExtension.lowercased()) { args += ["-movflags", "+faststart"] }
                    try MediaEngine.ffmpeg(args + [out.path], duration: info.duration, ctx: ctx)
                    return [out]
                }
            }
            JobCenter.shared.run(title: tool.progressVerb, steps: steps, anchor: anchor)

        case .splitPDF:
            let steps = urls.map { src in
                JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
                    try PDFEngine.split(src, ctx: ctx)
                }
            }
            JobCenter.shared.run(title: tool.progressVerb, steps: steps, anchor: anchor)

        case .extractArchive:
            let steps = urls.map { src in
                JobStep(name: src.lastPathComponent, destination: src.deletingLastPathComponent()) { ctx in
                    try ArchiveEngine.extractHere(src, ctx: ctx)
                }
            }
            JobCenter.shared.run(title: tool.progressVerb, steps: steps, anchor: anchor)

        case .createPDF:
            let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let first = sorted[0]
            let name = sorted.count == 1 ? Output.name(first, ext: "pdf") : "\(Output.stem(first)) and \(sorted.count - 1) more.pdf"
            let step = JobStep(name: sorted.count == 1 ? first.lastPathComponent : "\(sorted.count) images",
                               destination: first.deletingLastPathComponent()) { ctx in
                var pages: [ImageEngine.Loaded] = []
                for (i, url) in sorted.enumerated() {
                    try ctx.checkCancelled()
                    var loaded = try ImageEngine.load(url)
                    // Keep pages a sensible size: phone photos would otherwise be 40 inches wide.
                    let longest = CGFloat(max(loaded.image.width, loaded.image.height)) * loaded.pointsPerPixel
                    if longest > 842 { loaded.pointsPerPixel *= 842 / longest }
                    pages.append(loaded)
                    ctx.progress(0.8 * Double(i + 1) / Double(sorted.count))
                }
                let out = ctx.output(name)
                try ImageEngine.writePDF(pages, to: out)
                return [out]
            }
            JobCenter.shared.run(title: tool.progressVerb, steps: [step], anchor: anchor)

        default:
            break
        }
    }
}
