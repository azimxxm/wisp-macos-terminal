import SwiftUI
import AppKit
import UserNotifications

/// Keys + defaults for Wisp's background-bell notification, read by both the Settings UI and the
/// bell handler in SurfaceView. Backed by `UserDefaults.standard` (same store as `@AppStorage`).
enum WispNotificationDefaults {
    static let enabledKey = "com.azimxxm.wisp.notifications.bellEnabled"
    static let soundKey = "com.azimxxm.wisp.notifications.sound"

    static var bellEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var soundEnabled: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
}

/// Notification preferences: manage the system permission, enable/disable the background-bell
/// notification, and toggle its sound.
struct NotificationSettingsView: View {
    @AppStorage(WispNotificationDefaults.enabledKey) private var bellEnabled = true
    @AppStorage(WispNotificationDefaults.soundKey) private var soundEnabled = true

    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                permissionRow
            } header: {
                Text("Permission")
            }

            Section {
                Toggle("Notify on terminal bell", isOn: $bellEnabled)
                Toggle("Play sound", isOn: $soundEnabled)
                    .disabled(!bellEnabled)
            } header: {
                Text("When Wisp is in the background")
            } footer: {
                Text("Claude Code rings the bell when it finishes a turn or is waiting for input. "
                    + "Wisp notifies you only when it isn't the frontmost app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStatus)
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch authStatus {
        case .authorized, .provisional:
            Label("Notifications are allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            HStack {
                Label("Blocked in System Settings", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") { openSystemSettings() }
            }
        default:
            HStack {
                Text("Wisp needs permission to show notifications.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Grant Permission") { requestPermission() }
            }
        }
    }

    private func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { authStatus = settings.authorizationStatus }
        }
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            refreshStatus()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}
