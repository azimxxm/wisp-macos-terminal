import Foundation

/// `wisp record`: saves a terminal's screen as an asciicast v2 file (plays with `asciinema play`
/// or any asciicast player), so a QA run can attach what actually happened.
extension WispCLI {
    private static let frameInterval: TimeInterval = 0.2
    private static let clearScreen = "\u{1b}[H\u{1b}[2J"

    private static var stopRequested = false

    static func record(_ args: inout Arguments) throws -> Int32 {
        let target = try terminalReference(&args)
        let seconds = args.option("--seconds").flatMap(TimeInterval.init)
        guard let file = args.next() else { throw CLIError.usage("record needs FILE.cast") }
        let path = absolutePath(file)

        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw CLIError.failed("can't write \(path)")
        }
        defer { try? handle.close() }

        signal(SIGINT) { _ in WispCLI.stopRequested = true }
        FileHandle.standardError.write("wisp: recording to \(path) — press Ctrl-C to stop\n")

        let first = try appleScript("return visible contents of \(target)")
        let lines = first.components(separatedBy: "\n")
        let width = max(80, lines.map(\.count).max() ?? 80)
        let header: [String: Any] = [
            "version": 2, "width": width, "height": max(24, lines.count),
            "timestamp": Int(Date().timeIntervalSince1970), "title": "wisp record"
        ]
        handle.write(try JSONSerialization.data(withJSONObject: header))
        handle.write("\n")

        let start = Date()
        var previous = ""
        while !stopRequested {
            let elapsed = Date().timeIntervalSince(start)
            if let seconds, elapsed >= seconds { break }
            let screen = try appleScript("return visible contents of \(target)")
            if screen != previous {
                previous = screen
                let frame = clearScreen + screen.replacingOccurrences(of: "\n", with: "\r\n")
                let event: [Any] = [(elapsed * 1000).rounded() / 1000, "o", frame]
                handle.write(try JSONSerialization.data(withJSONObject: event))
                handle.write("\n")
            }
            Thread.sleep(forTimeInterval: frameInterval)
        }
        print(path)
        return 0
    }
}
