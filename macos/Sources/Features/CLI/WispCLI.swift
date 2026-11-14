import AppKit
import Foundation

/// `wisp` — a command line for AI agents and QA scripts running inside Wisp.
///
/// The app binary is linked as `Contents/MacOS/wisp`; when started under that name it runs this
/// CLI instead of the GUI. Terminal commands talk to the running Wisp through its AppleScript
/// dictionary; Mac commands (ax, click, screenshot) run right here and use the permissions
/// Wisp was granted.
enum WispCLI {
    static let usage = """
    wisp — drive Wisp terminals and the Mac from scripts and AI agents

    Terminals (default target: the terminal this command runs in; -t ID picks another):
      wisp list                                   id, tty, agent state, cwd, title of every terminal
      wisp new [--split right|down|left|up] [--cwd DIR] [--cmd CMD]
                                                  open a tab (or split this terminal); prints its id
      wisp send [-t ID] TEXT...                   type text (no Enter)
      wisp key [-t ID] KEY [--mods ctrl,shift]    press a key: enter, tab, escape, up, c, ...
      wisp run -t ID [--timeout S] COMMAND...     run a command in another terminal, wait for it,
                                                  print its output and exit with its exit code
      wisp read [-t ID] [--all|--last]            print screen text (--all: with scrollback,
                                                  --last: output of the last command)
      wisp wait [-t ID] [--timeout S] REGEX       wait until the screen matches REGEX
      wisp record [-t ID] [--seconds N] FILE.cast record the screen as an asciicast (Ctrl-C stops)
      wisp focus|close -t ID

    Mac (uses Wisp's Accessibility / Screen Recording permissions):
      wisp ax tree [--app NAME|--pid PID] [--depth N]   print the UI tree of an app
      wisp ax press TITLE [--app NAME|--pid PID]        press the first button with TITLE
      wisp click X Y [--right] [--double]               click at screen point X,Y
      wisp type TEXT                                    type text into the focused app
      wisp screenshot [--app NAME] FILE.png             whole screen, or the front window of NAME
      wisp perms                                        which permissions are working

    Exit codes: 0 ok, 1 failed or timed out, 2 bad usage; `run` exits with the command's code.
    """

    /// Entry point. Returns the process exit code.
    static func main(_ arguments: [String]) -> Int32 {
        var args = Arguments(arguments)
        guard let command = args.next() else {
            print(usage)
            return 0
        }
        do {
            switch command {
            case "list": return try listTerminals()
            case "new": return try newTerminal(&args)
            case "send": return try sendText(&args)
            case "key": return try key(&args)
            case "run": return try run(&args)
            case "read": return try readScreen(&args)
            case "wait": return try waitForText(&args)
            case "record": return try record(&args)
            case "focus", "close": return try focusOrClose(command, &args)
            case "ax": return try accessibility(&args)
            case "click": return try click(&args)
            case "type": return try typeText(&args)
            case "screenshot": return try screenshot(&args)
            case "perms": return permissions()
            case "help", "-h", "--help": print(usage); return 0
            default: throw CLIError.usage("unknown command '\(command)'")
            }
        } catch CLIError.usage(let message) {
            FileHandle.standardError.write("wisp: \(message)\nRun `wisp help` for usage.\n")
            return 2
        } catch {
            FileHandle.standardError.write("wisp: \(error.localizedDescription)\n")
            return 1
        }
    }
}

// MARK: - Errors and arguments

enum CLIError: LocalizedError {
    case usage(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .failed(let message): return message
        }
    }
}

/// Tiny argument reader: options (`--name value`, `-t value`, flags) can appear anywhere.
struct Arguments {
    private var items: [String]

    init(_ items: [String]) { self.items = items }

    mutating func next() -> String? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Removes `name value` and returns value.
    mutating func option(_ names: String...) -> String? {
        guard let index = items.firstIndex(where: { names.contains($0) }), index + 1 < items.count else { return nil }
        let value = items[index + 1]
        items.removeSubrange(index...(index + 1))
        return value
    }

    /// Removes a bare flag and reports whether it was there.
    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }

    mutating func rest() -> [String] {
        defer { items.removeAll() }
        return items
    }
}
