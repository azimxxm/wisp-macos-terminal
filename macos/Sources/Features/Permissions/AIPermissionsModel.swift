import AppKit
import Combine

/// Keeps the permission list live while the window is open: the user flips switches in
/// System Settings and the rows update on their own.
@MainActor
final class AIPermissionsModel: ObservableObject {
    @Published private(set) var statuses: [AIPermission: PermissionStatus] = [:]
    @Published private(set) var busy: AIPermission?

    /// Permissions requested in this run that macOS only applies after a restart.
    private var requestedThisRun: Set<AIPermission> = []
    private var timer: Timer?
    private static let pollInterval: TimeInterval = 1

    var allRequiredGranted: Bool {
        AIPermission.allCases.filter(\.isRequired).allSatisfy { statuses[$0] == .granted }
    }

    var needsRelaunch: Bool { statuses.values.contains(.needsRelaunch) }

    func status(of permission: AIPermission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func startPolling() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        for permission in AIPermission.allCases {
            var status = await PermissionProbe.status(of: permission)
            if status != .granted, permission.appliesAfterRelaunch, requestedThisRun.contains(permission) {
                status = .needsRelaunch
            }
            statuses[permission] = status
        }
    }

    func request(_ permission: AIPermission) async {
        busy = permission
        defer { busy = nil }
        if permission.appliesAfterRelaunch { requestedThisRun.insert(permission) }
        await PermissionProbe.request(permission)
        await refresh()
    }

    /// Starts a fresh copy of Wisp once this one has quit, then quits.
    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundlePath]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
