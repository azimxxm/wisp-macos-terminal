import AppKit
import ApplicationServices
import AVFoundation
import CoreServices
import UserNotifications

/// The current state of a single macOS privacy permission.
enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    /// Turned on in System Settings, but macOS only applies it after Wisp restarts.
    case needsRelaunch
}

/// Every permission an AI agent (Claude Code, Codex, ...) running inside Wisp needs to work
/// without stopping. Child processes inherit these from Wisp, so they are asked for up front.
enum AIPermission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case fullDiskAccess
    case automation
    case microphone
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .fullDiskAccess: return "Full Disk Access"
        case .automation: return "Automation (System Events)"
        case .microphone: return "Microphone"
        case .notifications: return "Notifications"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: return "Lets AI click, type and drive other apps on your Mac."
        case .screenRecording: return "Lets AI take screenshots and see what is on screen."
        case .fullDiskAccess: return "Lets AI read and edit files anywhere, including protected folders."
        case .automation: return "Lets AI run AppleScript and control apps through System Events."
        case .microphone: return "Lets voice tools hear you when you talk to the AI."
        case .notifications: return "Tells you when a long AI task finishes or needs your input."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "figure.wave"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .fullDiskAccess: return "externaldrive.fill"
        case .automation: return "gearshape.2.fill"
        case .microphone: return "mic.fill"
        case .notifications: return "bell.badge.fill"
        }
    }

    /// Optional permissions do not make the window pop up on launch by themselves.
    var isRequired: Bool {
        switch self {
        case .microphone, .notifications: return false
        default: return true
        }
    }

    /// macOS caches screen-capture access per process, so a fresh grant needs a restart.
    var appliesAfterRelaunch: Bool { self == .screenRecording }

    var settingsURL: URL? {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .automation: pane = "Privacy_Automation"
        case .microphone: pane = "Privacy_Microphone"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// Reads and requests permissions. Calls that can block (Apple Events) run off the main thread.
enum PermissionProbe {
    private static let systemEventsBundleID = "com.apple.systemevents"

    static func status(of permission: AIPermission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .fullDiskAccess:
            return fullDiskAccessStatus()
        case .automation:
            return await Task.detached { automationStatus(askUser: false) }.value
        case .microphone:
            return microphoneStatus()
        case .notifications:
            return await notificationStatus()
        }
    }

    /// Shows the system prompt where macOS has one, and opens the right Settings pane otherwise.
    static func request(_ permission: AIPermission) async {
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(for: permission) }
        case .screenRecording:
            // Adds Wisp to the list (and shows the prompt the first time), then opens the pane.
            if !CGRequestScreenCaptureAccess() { openSettings(for: permission) }
        case .fullDiskAccess:
            // There is no prompt API for this one; the user has to flip the switch.
            openSettings(for: permission)
        case .automation:
            await launchSystemEvents()
            let result = await Task.detached { automationStatus(askUser: true) }.value
            if result == .denied { openSettings(for: permission) }
        case .microphone:
            if microphoneStatus() == .denied {
                openSettings(for: permission)
            } else {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        case .notifications:
            if await notificationStatus() == .denied {
                openSettings(for: permission)
            } else {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    static func openSettings(for permission: AIPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Individual checks

    /// Full Disk Access has no query API, so we try to list a folder that only FDA can read.
    private static func fullDiskAccessStatus() -> PermissionStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = ["Library/Safari", "Library/Mail", "Library/Messages"].map { home.appendingPathComponent($0).path }
        guard let probe = probes.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .notDetermined
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil ? .granted : .denied
    }

    private static func automationStatus(askUser: Bool) -> PermissionStatus {
        var target = AEAddressDesc()
        let created = systemEventsBundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, systemEventsBundleID.utf8.count, &target)
        }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
        switch Int(result) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .denied
        default: return .notDetermined // not asked yet, or System Events is not running
        }
    }

    /// Apple Events permission can only be asked while the target app is running.
    private static func launchSystemEvents() async {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private static func notificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        default: return .notDetermined
        }
    }
}
