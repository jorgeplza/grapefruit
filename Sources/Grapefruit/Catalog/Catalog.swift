import Foundation
import UniformTypeIdentifiers

/// Which wheel is open. Each one is summoned by its own modifier key.
enum WheelMode: String, CaseIterable {
    case conversions, tools, actions
}

/// Formats are plain lowercase ids ("jpg", "gz", "textClipping"), the same ids
/// the output extensions are derived from.
enum Catalog {
    // Families. Order matters: it is the clockwise petal order, starting at 12 o'clock.
    static let imageTargets = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]
    static let imageInputs = ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]
    static let audio = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    static let video = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
    static let subtitles = ["srt", "vtt"]
    static let documents = ["docx", "pages", "md", "rtf", "rtfd", "textClipping"]
    static let sheets = ["xlsx", "xls", "ods", "csv", "tsv"]
    static let documentTargets = ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"]
    static let archives = ["zip", "tar", "gz", "rar"]
    /// Formats Grapefruit reads but never writes.
    static let inputOnly: Set<String> = ["rar", "ppt", "xls", "rtf", "rtfd", "textClipping"]

    // Extra inputs this copy accepts on top of the original list. They convert
    // into the same targets as their family.
    static let extraAudioInputs = ["aac", "caf", "m4b", "amr", "mka"]
    static let extraVideoInputs = ["m4v", "3gp", "mts", "m2ts", "ts", "mpg", "mpeg", "flv", "ogv", "f4v"]

    /// Canonical format id for a file on disk, or "folder".
    static func format(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "gz" }
        let ext = url.pathExtension.lowercased()
        if let mapped = extensionMap[ext] { return mapped }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return "folder"
        }
        // Fall back to the system's idea of the type.
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .jpeg) { return "jpg" }
            if type.conforms(to: .png) { return "png" }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return "heic" }
            if type.conforms(to: .tiff) { return "tiff" }
            if type.conforms(to: .pdf) { return "pdf" }
            if type.conforms(to: .mpeg4Movie) { return "mp4" }
            if type.conforms(to: .quickTimeMovie) { return "mov" }
            if type.conforms(to: .mp3) { return "mp3" }
            if type.conforms(to: .wav) { return "wav" }
            if type.conforms(to: .plainText) { return "txt" }
        }
        return ext.isEmpty ? nil : ext
    }

    private static let extensionMap: [String: String] = {
        var m: [String: String] = [
            "jpg": "jpg", "jpeg": "jpg", "jpe": "jpg", "jfif": "jpg",
            "png": "png", "webp": "webp", "heic": "heic", "heif": "heic", "hif": "heic",
            "tif": "tiff", "tiff": "tiff", "avif": "avif", "bmp": "bmp", "svg": "svg", "gif": "gif",
            "pdf": "pdf",
            "mp3": "mp3", "m4a": "m4a", "wav": "wav", "wave": "wav", "flac": "flac",
            "ogg": "ogg", "oga": "ogg", "opus": "opus", "aif": "aiff", "aiff": "aiff", "aifc": "aiff", "wma": "wma",
            "mp4": "mp4", "mov": "mov", "qt": "mov", "mkv": "mkv", "webm": "webm", "avi": "avi", "wmv": "wmv",
            "docx": "docx", "pages": "pages", "md": "md", "markdown": "md", "mdown": "md", "mkd": "md",
            "rtf": "rtf", "rtfd": "rtfd", "textclipping": "textClipping", "txt": "txt", "text": "txt",
            "html": "html", "htm": "html", "epub": "epub",
            "ppt": "ppt", "pptx": "pptx",
            "xlsx": "xlsx", "xls": "xls", "ods": "ods", "csv": "csv", "tsv": "tsv", "tab": "tsv",
            "srt": "srt", "vtt": "vtt",
            "zip": "zip", "tar": "tar", "gz": "gz", "tgz": "gz", "rar": "rar",
        ]
        for e in extraAudioInputs { m[e] = e }
        for e in extraVideoInputs { m[e] = e }
        return m
    }()

    static func isAudio(_ f: String) -> Bool { audio.contains(f) || extraAudioInputs.contains(f) }
    static func isVideo(_ f: String) -> Bool { video.contains(f) || extraVideoInputs.contains(f) }
    static func isImage(_ f: String) -> Bool { imageInputs.contains(f) }
    static func isDocument(_ f: String) -> Bool { documents.contains(f) || ["txt", "html", "epub"].contains(f) }
    static func isSheet(_ f: String) -> Bool { sheets.contains(f) }
    static func isArchive(_ f: String) -> Bool { archives.contains(f) }

    /// Conversion targets for one source format, in petal order.
    static func conversionTargets(for f: String) -> [String] {
        var t: [String] = []
        if imageInputs.contains(f) { t = imageTargets }
        else if isAudio(f) { t = audio }
        else if isVideo(f) { t = video + ["gif", "mp3"] }
        else if f == "gif" { t = video }
        else if f == "pdf" { t = ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"] }
        else if f == "ppt" || f == "pptx" { t = ["pdf", "jpg", "png"] }
        else if sheets.contains(f) { t = sheets + ["pdf"] }
        else if documents.contains(f) || f == "html" { t = documentTargets }
        else if f == "epub" { t = ["pdf", "docx", "pages", "txt", "md", "html"] }
        else if f == "txt" { t = ["docx", "pages", "pdf", "md", "html", "epub", "jpg", "png"] }
        else if subtitles.contains(f) { t = subtitles + ["txt"] }
        else if archives.contains(f) { t = ["zip", "tar", "gz"] }
        return t.filter { $0 != f && !inputOnly.contains($0) }
    }

    /// Targets for a whole selection: the union across formats, in petal order.
    /// Mixed families (say, a photo and a song) share nothing, so they get none.
    static func conversionTargets(forFormats formats: [String]) -> [String] {
        let distinct = Array(Set(formats))
        guard let first = distinct.first else { return [] }
        if distinct.count == 1 { return conversionTargets(for: first) }
        let families = Set(distinct.map(family))
        guard families.count == 1 else { return [] }
        var ordered: [String] = []
        for f in formats {
            for t in conversionTargets(for: f) where !ordered.contains(t) { ordered.append(t) }
        }
        // Keep the family's canonical order.
        let canonical = (imageTargets + audio + video + ["gif", "mp3"] + documentTargets + sheets + ["pdf"] + subtitles + ["txt"] + ["zip", "tar", "gz"])
        return ordered.sorted { (canonical.firstIndex(of: $0) ?? 99) < (canonical.firstIndex(of: $1) ?? 99) }
    }

    static func family(_ f: String) -> String {
        if isImage(f) { return "image" }
        if isAudio(f) { return "audio" }
        if isVideo(f) || f == "gif" { return "video" }
        if f == "pdf" { return "pdf" }
        if f == "ppt" || f == "pptx" { return "slides" }
        if isSheet(f) { return "sheet" }
        if isDocument(f) { return "document" }
        if subtitles.contains(f) { return "subtitle" }
        if isArchive(f) { return "archive" }
        return f
    }

    static func displayName(_ f: String) -> String {
        f == "gz" ? "GZIP" : f.uppercased()
    }

    /// File extension written for a target format.
    static func fileExtension(for f: String) -> String {
        switch f {
        case "gz": return "tar.gz"
        default: return f
        }
    }
}

// MARK: - Tools (the Command wheel)

enum ToolID: String, CaseIterable {
    case compress, removeMetadata, editImage, annotateImage, frameImage, cropImage
    case normalizeAudio, muteVideo, trimVideo, splitPDF, organizePDF, extractArchive
    case createPDF, mergePDF, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots
    case splitVideo, audioToVideo, trimAudio, audioChannels, createCollage
    case redactImage, redactVideo, redactAudio

    /// Petal label.
    var title: String {
        switch self {
        case .compress: "COMPRESS"
        case .removeMetadata: "METADATA"
        case .editImage: "EDIT"
        case .annotateImage: "ANNOTATE"
        case .frameImage: "ADD BG"
        case .cropImage, .cropVideo: "CROP"
        case .normalizeAudio: "NORMALIZE"
        case .muteVideo: "MUTE"
        case .trimVideo, .trimAudio: "TRIM"
        case .splitPDF, .splitVideo: "SPLIT"
        case .organizePDF: "ORGANIZE"
        case .extractArchive: "EXTRACT"
        case .createPDF: "CREATE PDF"
        case .mergePDF: "MERGE PDF"
        case .changeVideoSpeed: "SPEED"
        case .joinVideos: "JOIN"
        case .videoSnapshots: "SNAPSHOT"
        case .audioToVideo: "VISUALIZE"
        case .audioChannels: "CHANNELS"
        case .createCollage: "COLLAGE"
        case .redactImage, .redactVideo: "REDACT"
        case .redactAudio: "BLEEP"
        }
    }

    /// Window title and toast wording.
    var name: String {
        switch self {
        case .compress: "Compress"
        case .removeMetadata: "Metadata"
        case .editImage: "Edit Photo"
        case .annotateImage: "Annotate Photo"
        case .frameImage: "Add BG"
        case .cropImage: "Crop Image"
        case .normalizeAudio: "Normalize Volume"
        case .muteVideo: "Remove Audio"
        case .trimVideo: "Trim Video"
        case .splitPDF: "Split PDF"
        case .organizePDF: "Organize PDF"
        case .extractArchive: "Extract Archive"
        case .createPDF: "Create PDF"
        case .mergePDF: "Merge PDFs"
        case .cropVideo: "Crop Video"
        case .changeVideoSpeed: "Change Video Speed"
        case .joinVideos: "Join Videos"
        case .videoSnapshots: "Video Snapshots"
        case .splitVideo: "Split Video"
        case .audioToVideo: "Audio Visualizer"
        case .trimAudio: "Trim Audio"
        case .audioChannels: "Convert Audio Channels"
        case .createCollage: "Create Collage"
        case .redactImage: "Redact Photo"
        case .redactVideo: "Redact Video"
        case .redactAudio: "Bleep Audio"
        }
    }

    /// SF Symbol shown on the petal.
    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: "tag"
        case .editImage: "slider.horizontal.3"
        case .annotateImage: "pencil.and.outline"
        case .frameImage: "photo.artframe"
        case .cropImage, .cropVideo: "crop"
        case .normalizeAudio, .audioToVideo: "waveform"
        case .muteVideo: "speaker.slash.fill"
        case .trimVideo, .trimAudio: "scissors"
        case .splitPDF: "rectangle.split.2x1"
        case .organizePDF: "square.grid.2x2"
        case .extractArchive: "archivebox"
        case .createPDF: "doc.badge.plus"
        case .mergePDF: "doc.on.doc"
        case .changeVideoSpeed: "speedometer"
        case .joinVideos: "film.stack"
        case .videoSnapshots: "camera"
        case .splitVideo: "film"
        case .audioChannels: "hifispeaker.2"
        case .createCollage: "rectangle.3.group"
        case .redactImage, .redactVideo: "eye.slash"
        case .redactAudio: "waveform.badge.minus"
        }
    }

    /// Tools that combine a selection into one output.
    var combinesSelection: Bool {
        [.createPDF, .mergePDF, .joinVideos, .createCollage].contains(self)
    }

    /// Tools that still make sense for several files at once.
    var worksOnSelection: Bool {
        [.compress, .removeMetadata, .cropImage, .normalizeAudio, .muteVideo, .splitPDF,
         .extractArchive, .createPDF, .mergePDF, .joinVideos, .createCollage].contains(self)
    }

    /// Tools that run straight away instead of opening a window.
    var runsInstantly: Bool {
        [.muteVideo, .splitPDF, .extractArchive, .createPDF].contains(self)
    }

    /// Word used in the progress card ("Compressing", "Extracting"...).
    var progressVerb: String {
        switch self {
        case .compress: "Compressing"
        case .removeMetadata: "Cleaning metadata"
        case .muteVideo: "Removing audio"
        case .splitPDF: "Splitting PDF"
        case .extractArchive: "Extracting"
        case .createPDF: "Creating PDF"
        case .mergePDF: "Merging PDFs"
        case .joinVideos: "Joining videos"
        case .createCollage: "Making collage"
        case .trimVideo, .trimAudio: "Trimming"
        case .cropImage, .cropVideo: "Cropping"
        case .changeVideoSpeed: "Changing speed"
        case .normalizeAudio: "Normalizing"
        case .audioChannels: "Converting channels"
        case .audioToVideo: "Rendering visualizer"
        case .splitVideo: "Splitting video"
        case .videoSnapshots: "Saving frames"
        case .organizePDF: "Saving PDF"
        case .redactImage, .redactVideo: "Redacting"
        case .redactAudio: "Bleeping"
        case .editImage: "Saving edit"
        case .annotateImage: "Saving annotations"
        case .frameImage: "Adding background"
        }
    }

    /// Suffix added to the output name, "photo Compressed.jpg".
    var outputSuffix: String {
        switch self {
        case .compress: "Compressed"
        case .removeMetadata: "No Metadata"
        case .editImage: "Edited"
        case .annotateImage: "Annotated"
        case .frameImage: "Background"
        case .cropImage, .cropVideo: "Cropped"
        case .normalizeAudio: "Normalized"
        case .muteVideo: "Muted"
        case .trimVideo, .trimAudio: "Trimmed"
        case .splitPDF: "Pages"
        case .organizePDF: "Organized"
        case .extractArchive: "Extracted"
        case .createPDF: "PDF"
        case .mergePDF: "Merged"
        case .changeVideoSpeed: "Speed"
        case .joinVideos: "Joined"
        case .videoSnapshots: "Snapshot"
        case .splitVideo: "Clips"
        case .audioToVideo: "Visualizer"
        case .audioChannels: "Mono"
        case .createCollage: "Collage"
        case .redactImage, .redactVideo: "Redacted"
        case .redactAudio: "Bleeped"
        }
    }

    /// Tools offered for a format, in petal order. `count` is the selection size.
    static func tools(for f: String, count: Int) -> [ToolID] {
        guard count >= 1 else { return [] }
        var list: [ToolID] = []
        if ["jpg", "png", "webp", "heic", "tiff"].contains(f) {
            list = count > 1
                ? [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage]
                : [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage]
        } else if f == "svg" {
            list = count > 1 ? [.createPDF, .createCollage] : []
        } else if ["mp3", "m4a", "wav", "flac"].contains(f) {
            list = [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio]
        } else if ["mp4", "mov", "mkv"].contains(f) {
            list = count > 1
                ? [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos]
                : [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots, .splitVideo, .redactVideo]
        } else if f == "gif" {
            list = [.removeMetadata]
        } else if f == "pdf" {
            list = count > 1
                ? [.compress, .removeMetadata, .splitPDF, .mergePDF]
                : [.compress, .removeMetadata, .splitPDF, .organizePDF]
        } else if ["zip", "tar", "gz", "rar"].contains(f) {
            list = [.extractArchive]
        }
        return count == 1 ? list : list.filter { $0.worksOnSelection }
    }

    /// Tools for a whole selection: only when every file shares the same tool set.
    static func tools(forFormats formats: [String]) -> [ToolID] {
        guard let first = formats.first else { return [] }
        let base = tools(for: first, count: formats.count)
        for f in formats.dropFirst() where tools(for: f, count: formats.count) != base {
            // Images of different kinds still share the image list.
            let imageKinds: Set<String> = ["jpg", "png", "webp", "heic", "tiff", "svg"]
            if Set(formats).isSubset(of: imageKinds) {
                return formats.contains("svg") ? [.createPDF, .createCollage] : tools(for: "jpg", count: formats.count)
            }
            return []
        }
        return base
    }
}

// MARK: - Actions (the Control wheel)

enum ActionID: String, CaseIterable {
    case airDrop, float, copy, move, copyPath, openTerminal

    var title: String {
        switch self {
        case .airDrop: "AIRDROP"
        case .float: "FLOAT"
        case .copy: "COPY"
        case .move: "MOVE"
        case .copyPath: "COPY PATH"
        case .openTerminal: "TERMINAL"
        }
    }

    var name: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .openTerminal: "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .float: "pin.fill"
        case .copy: "doc.on.doc"
        case .move: "folder"
        case .copyPath: "doc.text"
        case .openTerminal: "terminal"
        }
    }
}
