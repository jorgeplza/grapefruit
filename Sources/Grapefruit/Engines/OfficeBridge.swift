import AppKit

/// Formats only their own apps can read (PowerPoint, old Excel, Pages) go through those apps,
/// driven by AppleScript. macOS asks once for permission to control each app.
enum OfficeBridge {
    /// Office apps are sandboxed; files inside their own container open without a "Grant Access" prompt.
    private static func workFolder(for bundleID: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Caches/Grapefruit/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func run(_ lines: [String], args: [String], ctx: JobContext, app: String) throws {
        var arguments: [String] = []
        for line in lines { arguments += ["-e", line] }
        do {
            try Shell.run(Binaries.osascript, arguments + args, ctx: ctx, timeout: 240)
        } catch JobError.cancelled {
            throw JobError.cancelled
        } catch {
            let message = JobCenter.describe(error)
            if message.contains("-1743") || message.lowercased().contains("not authorized") {
                throw JobError.failed("Allow Grapefruit to control \(app) in System Settings › Privacy & Security › Automation.")
            }
            throw JobError.failed("\(app) couldn't export this file. \(message)")
        }
    }

    // MARK: Slides

    /// PowerPoint (or Keynote) saves the deck as a PDF.
    static func slidesToPDF(_ src: URL, ctx: JobContext) throws -> URL {
        if Capabilities.hasPowerPoint {
            let id = "com.microsoft.Powerpoint"
            let wasRunning = isRunning(id)
            let folder = try workFolder(for: id)
            let input = folder.appendingPathComponent("deck.\(src.pathExtension.lowercased())")
            let output = folder.appendingPathComponent("deck.pdf")
            try FileManager.default.copyItem(at: src, to: input)
            ctx.progress(0.15)
            try run([
                "on run argv",
                "set inFile to POSIX file (item 1 of argv)",
                "set outFile to (POSIX file (item 2 of argv)) as string",
                "tell application \"Microsoft PowerPoint\"",
                "open inFile",
                "set thePres to active presentation",
                "save thePres in outFile as save as PDF",
                "close thePres saving no",
                wasRunning ? "" : "quit",
                "end tell",
                "end run",
            ], args: [input.path, output.path], ctx: ctx, app: "PowerPoint")
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw JobError.failed("PowerPoint didn't save a PDF.")
            }
            return output
        }
        if Capabilities.hasKeynote {
            let id = "com.apple.iWork.Keynote"
            let wasRunning = isRunning(id)
            let folder = try workFolder(for: id)
            let output = folder.appendingPathComponent("deck.pdf")
            try run([
                "on run argv",
                "tell application \"Keynote\"",
                "set theDoc to open (POSIX file (item 1 of argv))",
                "export theDoc to (POSIX file (item 2 of argv)) as PDF",
                "close theDoc saving no",
                wasRunning ? "" : "quit",
                "end tell",
                "end run",
            ], args: [src.path, output.path], ctx: ctx, app: "Keynote")
            return output
        }
        throw JobError.failed("Opening slides needs PowerPoint or Keynote.")
    }

    // MARK: Spreadsheets

    /// Excel re-saves an old .xls as .xlsx so Grapefruit can read it.
    static func xlsToXLSX(_ src: URL, ctx: JobContext) throws -> URL {
        let id = "com.microsoft.Excel"
        guard Capabilities.hasExcel else { throw JobError.failed("Opening .xls files needs Microsoft Excel.") }
        let wasRunning = isRunning(id)
        let folder = try workFolder(for: id)
        let input = folder.appendingPathComponent("book.xls")
        let output = folder.appendingPathComponent("book.xlsx")
        try FileManager.default.copyItem(at: src, to: input)
        try run([
            "on run argv",
            "tell application \"Microsoft Excel\"",
            "open workbook workbook file name (item 1 of argv)",
            "set wb to active workbook",
            "save workbook as wb filename (item 2 of argv) file format Excel XML file format",
            "close wb saving no",
            wasRunning ? "" : "quit",
            "end tell",
            "end run",
        ], args: [input.path, output.path], ctx: ctx, app: "Excel")
        guard FileManager.default.fileExists(atPath: output.path) else { throw JobError.failed("Excel didn't save the workbook.") }
        return output
    }

    // MARK: Pages

    /// Pages exports a .pages document as Word so it can be read.
    static func exportPages(_ src: URL, as format: String, ctx: JobContext) throws -> URL {
        guard Capabilities.hasPages else { throw JobError.failed("Opening .pages files needs Pages.") }
        let id = "com.apple.iWork.Pages"
        let wasRunning = isRunning(id)
        let folder = try workFolder(for: id)
        let output = folder.appendingPathComponent("document.docx")
        try run([
            "on run argv",
            "tell application \"Pages\"",
            "set theDoc to open (POSIX file (item 1 of argv))",
            "export theDoc to (POSIX file (item 2 of argv)) as Microsoft Word",
            "close theDoc saving no",
            wasRunning ? "" : "quit",
            "end tell",
            "end run",
        ], args: [src.path, output.path], ctx: ctx, app: "Pages")
        return output
    }

    /// Pages opens a Word file and saves it as a Pages document.
    static func convertWithPages(_ docx: URL, to out: URL, ctx: JobContext) throws {
        guard Capabilities.hasPages else { throw JobError.failed("Saving .pages files needs Pages.") }
        let id = "com.apple.iWork.Pages"
        let wasRunning = isRunning(id)
        let folder = try workFolder(for: id)
        let input = folder.appendingPathComponent("document.docx")
        let output = folder.appendingPathComponent("document.pages")
        try FileManager.default.copyItem(at: docx, to: input)
        try run([
            "on run argv",
            "tell application \"Pages\"",
            "set theDoc to open (POSIX file (item 1 of argv))",
            "save theDoc in (POSIX file (item 2 of argv))",
            "close theDoc saving no",
            wasRunning ? "" : "quit",
            "end tell",
            "end run",
        ], args: [input.path, output.path], ctx: ctx, app: "Pages")
        try FileManager.default.moveItem(at: output, to: out)
    }
}
