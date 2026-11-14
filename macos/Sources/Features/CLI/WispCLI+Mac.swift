import AppKit
import ApplicationServices
import CoreGraphics

/// Mac control commands. They need Accessibility (ax, click, type) and Screen Recording
/// (screenshot), which this process inherits from Wisp.
extension WispCLI {
    private static let defaultTreeDepth = 12
    private static let keystrokeDelay: useconds_t = 8_000

    static func accessibility(_ args: inout Arguments) throws -> Int32 {
        try requireAccessibility()
        guard let sub = args.next() else { throw CLIError.usage("ax needs tree or press") }
        let app = try targetApplication(&args)
        switch sub {
        case "tree":
            let depth = args.option("--depth").flatMap(Int.init) ?? defaultTreeDepth
            printTree(app, depth: 0, maxDepth: depth)
            return 0
        case "press":
            let title = args.rest().joined(separator: " ")
            guard !title.isEmpty else { throw CLIError.usage("ax press needs a TITLE") }
            guard let button = findElement(in: app, role: kAXButtonRole, title: title) else {
                throw CLIError.failed("no button titled '\(title)'")
            }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard result == .success else { throw CLIError.failed("press failed (AXError \(result.rawValue))") }
            return 0
        default:
            throw CLIError.usage("unknown ax command '\(sub)'")
        }
    }

    static func click(_ args: inout Arguments) throws -> Int32 {
        try requireAccessibility()
        let right = args.flag("--right")
        let double = args.flag("--double")
        guard let x = args.next().flatMap(Double.init), let y = args.next().flatMap(Double.init) else {
            throw CLIError.usage("click needs X Y")
        }
        let point = CGPoint(x: x, y: y)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        for clickCount in 1...(double ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                event?.post(tap: .cghidEventTap)
            }
        }
        return 0
    }

    static func typeText(_ args: inout Arguments) throws -> Int32 {
        try requireAccessibility()
        let text = args.rest().joined(separator: " ")
        guard !text.isEmpty else { throw CLIError.usage("type needs TEXT") }
        for unit in text.utf16 {
            var character = unit
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event?.post(tap: .cghidEventTap)
            }
            usleep(keystrokeDelay)
        }
        return 0
    }

    static func screenshot(_ args: inout Arguments) throws -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            throw CLIError.failed("Screen Recording is off for Wisp — open Help ▸ AI Permissions…")
        }
        let appName = args.option("--app")
        guard let file = args.next() else { throw CLIError.usage("screenshot needs FILE.png") }
        var arguments = ["-x", absolutePath(file)]
        if let appName {
            guard let windowID = frontWindowID(ofAppNamed: appName) else {
                throw CLIError.failed("no visible window for '\(appName)'")
            }
            arguments.insert(contentsOf: ["-o", "-l", String(windowID)], at: 0)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError.failed("screencapture failed") }
        print(absolutePath(file))
        return 0
    }

    static func permissions() -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fullDisk = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Safari").path)) != nil
        let rows: [(String, Bool)] = [
            ("Accessibility", AXIsProcessTrusted()),
            ("Screen Recording", CGPreflightScreenCaptureAccess()),
            ("Full Disk Access", fullDisk)
        ]
        for (name, granted) in rows { print("\(granted ? "✓" : "✗") \(name)") }
        return rows.allSatisfy(\.1) ? 0 : 1
    }

    // MARK: - Helpers

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw CLIError.failed("Accessibility is off for Wisp — open Help ▸ AI Permissions…")
        }
    }

    /// `--pid PID`, `--app NAME`, or the frontmost app.
    private static func targetApplication(_ args: inout Arguments) throws -> AXUIElement {
        if let pid = args.option("--pid").flatMap(pid_t.init) { return AXUIElementCreateApplication(pid) }
        if let name = args.option("--app") {
            guard let app = runningApp(named: name) else { throw CLIError.failed("'\(name)' is not running") }
            return AXUIElementCreateApplication(app.processIdentifier)
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { throw CLIError.failed("no frontmost app") }
        return AXUIElementCreateApplication(front.processIdentifier)
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name
        }
    }

    private static func frontWindowID(ofAppNamed name: String) -> CGWindowID? {
        guard let app = runningApp(named: name),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let window = windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return window?[kCGWindowNumber as String] as? CGWindowID
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func label(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .compactMap { attribute(element, $0) as? String }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private static func printTree(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let text = label(element)
        print(String(repeating: "  ", count: depth) + role + (text.isEmpty ? "" : ": " + text))
        for child in children(element) { printTree(child, depth: depth + 1, maxDepth: maxDepth) }
    }

    private static func findElement(in element: AXUIElement, role: String, title: String) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == role,
           [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { attribute(element, $0) as? String == title }) {
            return element
        }
        for child in children(element) {
            if let match = findElement(in: child, role: role, title: title) { return match }
        }
        return nil
    }
}
