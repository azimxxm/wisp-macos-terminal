import Foundation

/// Terminal commands. They run AppleScript against the Wisp app that hosts this process.
extension WispCLI {
    private static let pollInterval: TimeInterval = 0.1
    private static let defaultTimeout: TimeInterval = 120

    static func listTerminals() throws -> Int32 {
        let script = """
        set out to ""
        set sep to character id 9
        repeat with t in terminals
            set out to out & (id of t) & sep & (tty of t) & sep & (agent state of t) & sep & (working directory of t) & sep & (name of t) & linefeed
        end repeat
        return out
        """
        print(try appleScript(script), terminator: "")
        return 0
    }

    static func newTerminal(_ args: inout Arguments) throws -> Int32 {
        // A surface configuration object carries the optional cwd / command.
        var setup = ["set config to new surface configuration"]
        if let cwd = args.option("--cwd") {
            setup.append("set initial working directory of config to \(quoted(absolutePath(cwd)))")
        }
        if let cmd = args.option("--cmd") { setup.append("set command of config to \(quoted(cmd))") }

        let create: String
        if let direction = args.option("--split") {
            guard ["right", "down", "left", "up"].contains(direction) else {
                throw CLIError.usage("--split takes right, down, left or up")
            }
            let target = try terminalReference(&args)
            create = "return id of (split \(target) direction \(direction) with configuration config)"
        } else {
            create = """
            if (count of windows) is 0 then
                return id of focused terminal of selected tab of (new window with configuration config)
            end if
            return id of focused terminal of (new tab in front window with configuration config)
            """
        }
        print(try appleScript((setup + [create]).joined(separator: "\n")))
        return 0
    }

    static func sendText(_ args: inout Arguments) throws -> Int32 {
        let target = try terminalReference(&args)
        let text = args.rest().joined(separator: " ")
        guard !text.isEmpty else { throw CLIError.usage("send needs TEXT") }
        _ = try appleScript("input text \(quoted(text)) to \(target)")
        return 0
    }

    static func key(_ args: inout Arguments) throws -> Int32 {
        let target = try terminalReference(&args)
        let mods = args.option("--mods").map { " modifiers \(quoted($0))" } ?? ""
        guard let name = args.next() else { throw CLIError.usage("key needs a KEY name") }
        _ = try appleScript("send key \(quoted(name))\(mods) to \(target)")
        return 0
    }

    /// Types COMMAND + Enter into another terminal, waits for the shell to report it finished,
    /// prints its output and returns its exit code.
    static func run(_ args: inout Arguments) throws -> Int32 {
        guard let id = args.option("-t", "--terminal") else {
            throw CLIError.usage("run needs -t ID (a different terminal; see `wisp list` or `wisp new`)")
        }
        let timeout = args.option("--timeout").flatMap(TimeInterval.init) ?? defaultTimeout
        let command = args.rest().joined(separator: " ")
        guard !command.isEmpty else { throw CLIError.usage("run needs a COMMAND") }
        if let own = try? ownTerminalID(), own == id {
            throw CLIError.usage("run can't target its own terminal; open one with `wisp new`")
        }

        let target = "terminal id \(quoted(id))"
        let before = Int(try appleScript("return finished commands of \(target)")) ?? 0
        _ = try appleScript("input text \(quoted(command)) to \(target)")
        _ = try appleScript("send key \"enter\" to \(target)")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = Int(try appleScript("return finished commands of \(target)")) ?? 0
            if count > before {
                let output = try appleScript("return last command output of \(target)")
                print(output, terminator: output.isEmpty || output.hasSuffix("\n") ? "" : "\n")
                return Int32(clamping: Int(try appleScript("return last exit status of \(target)")) ?? 1)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        throw CLIError.failed("timed out after \(Int(timeout))s waiting for the command to finish")
    }

    static func readScreen(_ args: inout Arguments) throws -> Int32 {
        let target = try terminalReference(&args)
        let property: String
        if args.flag("--all") {
            property = "contents"
        } else if args.flag("--last") {
            property = "last command output"
        } else {
            property = "visible contents"
        }
        print(try appleScript("return \(property) of \(target)"))
        return 0
    }

    static func waitForText(_ args: inout Arguments) throws -> Int32 {
        let target = try terminalReference(&args)
        let timeout = args.option("--timeout").flatMap(TimeInterval.init) ?? defaultTimeout
        guard let pattern = args.next() else { throw CLIError.usage("wait needs a REGEX") }
        let regex = try NSRegularExpression(pattern: pattern)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let screen = try appleScript("return visible contents of \(target)")
            if regex.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) != nil { return 0 }
            Thread.sleep(forTimeInterval: pollInterval * 3)
        }
        FileHandle.standardError.write("wisp: timed out waiting for /\(pattern)/\n")
        return 1
    }

    static func focusOrClose(_ command: String, _ args: inout Arguments) throws -> Int32 {
        guard let id = args.option("-t", "--terminal") else { throw CLIError.usage("\(command) needs -t ID") }
        _ = try appleScript("\(command) terminal id \(quoted(id))")
        return 0
    }

    // MARK: - Helpers

    /// `-t ID` if given, otherwise the terminal whose tty is ours.
    static func terminalReference(_ args: inout Arguments) throws -> String {
        if let id = args.option("-t", "--terminal") { return "terminal id \(quoted(id))" }
        return "terminal id \(quoted(try ownTerminalID()))"
    }

    static func ownTerminalID() throws -> String {
        guard let tty = ttyname(STDIN_FILENO) ?? ttyname(STDOUT_FILENO) else {
            throw CLIError.usage("not running in a terminal; pass -t ID")
        }
        let path = String(cString: tty)
        let id = try appleScript("return id of first terminal whose tty is \(quoted(path))")
        guard !id.isEmpty else { throw CLIError.failed("this terminal (\(path)) is not a Wisp terminal") }
        return id
    }

    /// Runs AppleScript inside a `tell` block for the Wisp app this binary belongs to.
    /// It goes through `/usr/bin/osascript`: in-process NSAppleScript would see that this
    /// binary *is* Wisp (same bundle id) and send the events to itself instead of the app.
    static func appleScript(_ body: String) throws -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.azimxxm.wisp"
        let source = "tell application id \(quoted(bundleID))\n\(body)\nend tell"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = (String(bytes: errorData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.failed(message.isEmpty ? "AppleScript failed" : message)
        }
        // osascript adds one trailing newline to every result.
        var result = String(bytes: data, encoding: .utf8) ?? ""
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    /// An AppleScript string literal.
    static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).path
    }
}
