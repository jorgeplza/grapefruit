import AppKit

/// Command line tools Grapefruit leans on. Homebrew installs land in /opt/homebrew/bin.
enum Binaries {
    private static let folders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin"]

    static func find(_ name: String) -> URL? {
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")
    static let cwebp = find("cwebp")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    static func require(_ url: URL?, _ name: String) throws -> URL {
        guard let url else {
            throw JobError.failed("\(name) isn't installed. In Terminal: brew install \(name)")
        }
        return url
    }
}

enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs a tool to completion. Lines of standard output go to `onLine` as they arrive.
    /// Stops the tool when the job is cancelled. Throws when it exits with an error.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], ctx: JobContext? = nil,
                    environment: [String: String]? = nil, directory: URL? = nil,
                    collectOutput: Bool = true, allowFailure: Bool = false, timeout: TimeInterval? = nil,
                    onLine: ((String) -> Void)? = nil) throws -> Result {
        try ctx?.checkCancelled()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()

        try process.run()
        ctx?.track(process)
        defer { ctx?.untrack(process) }
        let timedOut = DataBox()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut.append(Data([1]))
                    process.terminate()
                }
            }
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = out.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if collectOutput { outBox.append(chunk) }
                guard let onLine else { continue }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    onLine(line)
                }
            }
            if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = err.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errBox.append(chunk, keepLast: 64_000)
            }
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        try ctx?.checkCancelled()
        if !timedOut.data.isEmpty {
            throw JobError.failed("\(executable.lastPathComponent) took too long and was stopped.")
        }

        let stderr = String(decoding: errBox.data, as: UTF8.self)
        let result = Result(status: process.terminationStatus, stdout: outBox.data, stderr: stderr)
        if process.terminationStatus != 0 && !allowFailure {
            throw JobError.failed(cleanError(stderr, tool: executable.lastPathComponent))
        }
        return result
    }

    /// The most useful line of a tool's error output.
    static func cleanError(_ stderr: String, tool: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Conversion failed") && !$0.hasPrefix("Error opening output files") }
        guard var line = lines.last else { return "\(tool) stopped with an error." }
        // ffmpeg prefixes lines with "[component @ 0x...]".
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if line.count > 160 { line = String(line.prefix(157)) + "…" }
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.withLock { storage } }

    func append(_ chunk: Data, keepLast limit: Int? = nil) {
        lock.withLock {
            storage.append(chunk)
            if let limit, storage.count > limit {
                storage.removeFirst(storage.count - limit)
            }
        }
    }
}

/// What this Mac can do. Targets that need something missing are hidden from the wheel.
enum Capabilities {
    static var hasFFmpeg: Bool { Binaries.ffmpeg != nil && Binaries.ffprobe != nil }
    static var hasWebPEncoder: Bool { Binaries.cwebp != nil || hasFFmpeg }

    nonisolated(unsafe) private static var appCache: [String: Bool] = [:]
    private static let cacheLock = NSLock()

    static func hasApp(_ bundleID: String) -> Bool {
        if let known = cacheLock.withLock({ appCache[bundleID] }) { return known }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        cacheLock.withLock { appCache[bundleID] = found }
        return found
    }

    static var hasPages: Bool { hasApp("com.apple.iWork.Pages") }
    static var hasKeynote: Bool { hasApp("com.apple.iWork.Keynote") }
    static var hasPowerPoint: Bool { hasApp("com.microsoft.Powerpoint") }
    static var hasExcel: Bool { hasApp("com.microsoft.Excel") }

    /// Look things up once at launch so the first wheel opens instantly.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = Binaries.ffmpeg
            _ = Binaries.cwebp
            _ = hasPages
            _ = hasKeynote
            _ = hasPowerPoint
            _ = hasExcel
        }
    }

    /// Can this Mac open the format at all?
    static func canRead(_ f: String) -> Bool {
        switch f {
        case "pages": return hasPages
        case "ppt", "pptx": return hasPowerPoint || hasKeynote
        case "xls": return hasExcel
        default:
            if Catalog.isAudio(f) || Catalog.isVideo(f) || f == "gif" { return hasFFmpeg }
            return true
        }
    }

    /// Should this target show on the wheel for these sources?
    static func canProduce(_ target: String, from formats: [String]) -> Bool {
        guard formats.allSatisfy(canRead) else { return false }
        switch target {
        case "pages": return hasPages
        case "webp": return hasWebPEncoder
        case "xls", "ppt": return false
        default: return true
        }
    }
}
