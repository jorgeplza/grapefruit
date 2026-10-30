import AppKit

@main
enum GrapefruitApp {
    static func main() {
        // Headless mode for testing the engines: Grapefruit --convert <file> <target> <output folder>
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--convert"), args.count > i + 3 {
            exit(Headless.convert(URL(fileURLWithPath: args[i + 1]), to: args[i + 2],
                                  into: URL(fileURLWithPath: args[i + 3])))
        }
        if let i = args.firstIndex(of: "--targets"), args.count > i + 1 {
            let url = URL(fileURLWithPath: args[i + 1])
            let format = Catalog.format(of: url) ?? ""
            print(Catalog.conversionTargets(for: format).filter { Capabilities.canProduce($0, from: [format]) }.joined(separator: " "))
            exit(0)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

enum Headless {
    static func convert(_ src: URL, to target: String, into folder: URL) -> Int32 {
        let fm = FileManager.default
        let area = fm.temporaryDirectory.appendingPathComponent("grapefruit-cli-\(UUID().uuidString)")
        let scratch = area.appendingPathComponent("out")
        defer { try? fm.removeItem(at: area) }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let ctx = JobContext(scratch: scratch) { _ in }
            ctx.destination = folder
            let started = Date()
            let outputs = try Converter.convert(src, to: target, ctx: ctx)
            for file in outputs {
                let destination = Output.unique(folder.appendingPathComponent(file.lastPathComponent), plainFolder: Output.isPlainFolder(file))
                try fm.moveItem(at: file, to: destination)
                print("OK \(String(format: "%.2fs", Date().timeIntervalSince(started))) \(destination.path)")
            }
            return 0
        } catch {
            print("FAIL \(src.lastPathComponent) -> \(target): \(JobCenter.describe(error))")
            return 1
        }
    }
}
