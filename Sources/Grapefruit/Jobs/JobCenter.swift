import AppKit
import Combine

/// Shared with the background work: where to write, how far along it is, and whether to stop.
final class JobContext: @unchecked Sendable {
    /// Private folder for this step's outputs. Everything left in it is moved next to the source.
    let scratch: URL
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []
    private let onProgress: (Double) -> Void
    private var lastSent = -1.0
    private var lastSentAt = Date.distantPast

    /// Where this step's outputs end up, when the job knows. Set before the work starts.
    var destination: URL?

    init(scratch: URL, onProgress: @escaping (Double) -> Void) {
        self.scratch = scratch
        self.onProgress = onProgress
    }

    /// The first of "name", "name 2", "name 3"... whose files are all free at the destination. For outputs that
    /// link to each other, like a Markdown file and its images folder, so the links still work after the move.
    func freeStem(_ stem: String, names: (String) -> [String]) -> String {
        guard let destination else { return stem }
        let fm = FileManager.default
        var candidate = stem
        var n = 2
        while names(candidate).contains(where: { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }) {
            candidate = "\(stem) \(n)"
            n += 1
        }
        return candidate
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func checkCancelled() throws {
        if isCancelled { throw JobError.cancelled }
    }

    func cancel() {
        let running: [Process] = lock.withLock {
            cancelled = true
            return processes
        }
        for p in running where p.isRunning { p.terminate() }
    }

    func track(_ process: Process) {
        let stopNow: Bool = lock.withLock {
            processes.append(process)
            return cancelled
        }
        if stopNow, process.isRunning { process.terminate() }
    }

    func untrack(_ process: Process) {
        lock.withLock { processes.removeAll { $0 === process } }
    }

    /// Progress of the current file, 0...1. Throttled so the card doesn't flood the main thread.
    func progress(_ value: Double) {
        let v = min(1, max(0, value))
        let now = Date()
        let send: Bool = lock.withLock {
            guard abs(v - lastSent) >= 0.004 || v >= 1 else { return false }
            guard now.timeIntervalSince(lastSentAt) > 0.03 || v >= 1 || lastSent < 0 else { return false }
            lastSent = v
            lastSentAt = now
            return true
        }
        if send { onProgress(v) }
    }

    /// A file in the scratch folder.
    func output(_ name: String) -> URL {
        scratch.appendingPathComponent(name)
    }

    /// A throwaway folder inside the scratch area that is not moved out at the end.
    func temporaryFolder() throws -> URL {
        let url = scratch.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum JobError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled"
        case .failed(let message): message
        }
    }
}

/// One unit of work: usually one source file.
struct JobStep: @unchecked Sendable {
    /// Shown in the card while this step runs.
    let name: String
    /// Folder the outputs land in.
    let destination: URL
    /// Writes its outputs into `ctx.scratch` and returns them.
    let work: (JobContext) throws -> [URL]
}

@MainActor
final class Job: ObservableObject, Identifiable {
    enum Phase: Equatable { case running, finished, failed, cancelled }

    let id = UUID()
    @Published var title: String
    @Published var itemName = ""
    @Published var itemProgress = 0.0
    @Published var progress = 0.0
    @Published var phase = Phase.running
    @Published var summary = ""
    /// A short notice with no progress bar ("Copied 2 files").
    let isNotice: Bool
    let total: Int
    var outputs: [URL] = []
    var errors: [String] = []
    var onCancel: (() -> Void)?

    init(title: String, total: Int, isNotice: Bool = false) {
        self.title = title
        self.total = total
        self.isNotice = isNotice
    }

    var detail: String {
        switch phase {
        case .running:
            return itemName
        case .finished, .failed, .cancelled:
            return summary
        }
    }

    var percentText: String? {
        guard phase == .running, !isNotice, !itemName.isEmpty else { return nil }
        let pct = Int((itemProgress * 100).rounded())
        return total > 1 ? "\(pct)% · \(min(total, completedSteps + 1)) of \(total)" : "\(pct)%"
    }

    var completedSteps = 0
}

/// Runs jobs off the main thread and shows a progress card for each.
@MainActor
final class JobCenter {
    static let shared = JobCenter()
    private let toasts = ToastController()

    /// Run `steps` one after another. `verb` reads like "Converting to MP3".
    @discardableResult
    func run(title: String, steps: [JobStep], anchor: NSPoint, reveal: Bool = false) -> Job {
        let job = Job(title: title, total: steps.count)
        toasts.show(job, at: anchor)
        let contexts = ContextBox()

        job.onCancel = { [weak job] in
            contexts.cancelAll()
            job?.phase = .cancelled
        }

        let queue = DispatchQueue(label: "grapefruit.job", qos: .userInitiated)
        queue.async {
            for (index, step) in steps.enumerated() {
                if contexts.isCancelled { break }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        job.itemName = step.name
                        job.itemProgress = 0
                        job.completedSteps = index
                        job.progress = Double(index) / Double(max(1, steps.count))
                    }
                }
                do {
                    let moved = try Self.perform(step, index: index, count: steps.count, job: job, contexts: contexts)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            job.outputs.append(contentsOf: moved)
                        }
                    }
                } catch JobError.cancelled {
                    break
                } catch {
                    let message = Self.describe(error)
                    NSLog("Grapefruit: \(step.name) failed: \(message)")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { job.errors.append(message) }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    JobCenter.shared.finish(job, reveal: reveal)
                }
            }
        }
        return job
    }

    /// One step: run it in a scratch folder on the destination's volume, then move the results out.
    nonisolated private static func perform(_ step: JobStep, index: Int, count: Int, job: Job,
                                            contexts: ContextBox) throws -> [URL] {
        let fm = FileManager.default
        var destination = step.destination
        if !fm.isWritableFile(atPath: destination.path) {
            destination = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let area = try Self.scratchArea(near: destination)
        defer { try? fm.removeItem(at: area) }
        let scratch = area.appendingPathComponent("out")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        let ctx = JobContext(scratch: scratch) { value in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard job.phase == .running else { return }
                    job.itemProgress = value
                    job.progress = (Double(index) + value) / Double(max(1, count))
                }
            }
        }
        ctx.destination = destination
        contexts.add(ctx)
        defer { contexts.remove(ctx) }

        let produced = try step.work(ctx)
        try ctx.checkCancelled()
        var moved: [URL] = []
        for file in produced {
            let target = Output.unique(destination.appendingPathComponent(file.lastPathComponent), plainFolder: Output.isPlainFolder(file))
            try fm.moveItem(at: file, to: target)
            moved.append(target)
        }
        return moved
    }

    nonisolated private static func scratchArea(near destination: URL) throws -> URL {
        let fm = FileManager.default
        if let url = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination, create: true) {
            return url
        }
        let url = fm.temporaryDirectory.appendingPathComponent("Grapefruit-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let local = error as? LocalizedError, let text = local.errorDescription { return text }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
            return "Grapefruit can't write to that folder."
        }
        return ns.localizedDescription
    }

    private func finish(_ job: Job, reveal: Bool) {
        if job.phase == .cancelled {
            toasts.dismiss(job, after: 0)
            return
        }
        let saved = job.outputs.count
        let failed = job.errors.count
        job.completedSteps = job.total
        job.itemProgress = 1
        if failed == 0 {
            job.phase = .finished
            job.progress = 1
            job.summary = job.total == 1 && saved > 1
                ? "\(saved) files saved"
                : "\(job.total - failed) of \(job.total) saved"
            toasts.dismiss(job, after: 1.4)
            if reveal || Settings.shared.revealAfterSaving, !job.outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
            }
        } else if failed < job.total {
            job.phase = .finished
            job.progress = 1
            job.summary = "\(job.total - failed) of \(job.total) saved. \(job.errors.first ?? "")"
            toasts.dismiss(job, after: 5)
        } else {
            job.phase = .failed
            job.summary = job.errors.first ?? "Something went wrong."
            toasts.dismiss(job, after: 7)
        }
    }

    /// A short confirmation with no progress ("Copied 2 files").
    func notice(_ title: String, detail: String, at anchor: NSPoint) {
        let job = Job(title: title, total: 1, isNotice: true)
        job.phase = .finished
        job.summary = detail
        job.progress = 1
        toasts.show(job, at: anchor)
        toasts.dismiss(job, after: 1.6)
    }

    /// An error that happened before any work started.
    func failure(_ title: String, detail: String, at anchor: NSPoint) {
        let job = Job(title: title, total: 1, isNotice: true)
        job.phase = .failed
        job.summary = detail
        toasts.show(job, at: anchor)
        toasts.dismiss(job, after: 6)
    }

    func reveal(_ job: Job) {
        guard !job.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
    }
}

/// Every running step's context, so one × can stop them all.
private final class ContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [JobContext] = []
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func add(_ ctx: JobContext) {
        let cancelNow: Bool = lock.withLock {
            contexts.append(ctx)
            return cancelled
        }
        if cancelNow { ctx.cancel() }
    }

    func remove(_ ctx: JobContext) {
        lock.withLock { contexts.removeAll { $0 === ctx } }
    }

    func cancelAll() {
        let all: [JobContext] = lock.withLock {
            cancelled = true
            return contexts
        }
        all.forEach { $0.cancel() }
    }
}

/// Output file naming: "photo.jpg", then "photo 2.jpg", "photo 3.jpg"...
enum Output {
    /// A plain folder ("v1.2 Clips") has no extension, so its number goes at the end: "v1.2 Clips 2".
    static func unique(_ url: URL, plainFolder: Bool = false) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let (stem, ext) = plainFolder ? (url.lastPathComponent, "") : split(url.lastPathComponent)
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// A folder that isn't a bundle like .rtfd, whose extension is part of what it is.
    static func isPlainFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
    }

    /// "archive.tar.gz" splits into ("archive", "tar.gz").
    static func split(_ name: String) -> (String, String) {
        let lower = name.lowercased()
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(double) && name.count > double.count {
            return (String(name.dropLast(double.count)), String(double.dropFirst()))
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        // Folders and dotfiles have no extension worth keeping.
        if ext.isEmpty || ns.deletingPathExtension.isEmpty { return (name, "") }
        return (ns.deletingPathExtension, ext)
    }

    /// The name without its extension ("archive" for "archive.tar.gz").
    static func stem(_ url: URL) -> String {
        split(url.lastPathComponent).0
    }

    /// "photo Compressed.jpg"
    static func name(_ url: URL, suffix: String? = nil, ext: String? = nil) -> String {
        let (stem, originalExt) = split(url.lastPathComponent)
        let base = suffix.map { "\(stem) \($0)" } ?? stem
        let e = ext ?? originalExt
        return e.isEmpty ? base : "\(base).\(e)"
    }
}
