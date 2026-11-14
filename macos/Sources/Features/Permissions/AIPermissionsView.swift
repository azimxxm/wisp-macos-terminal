import AppKit
import SwiftUI

/// "Get Wisp ready for AI": every permission an AI agent needs, each with its own Allow button.
/// Asking up front means an agent never stops mid-task waiting for a permission and a restart.
struct AIPermissionsView: View {
    @ObservedObject var model: AIPermissionsModel
    var onDone: () -> Void = {}

    private let accent = Color(red: 0.42, green: 0.56, blue: 1.0)

    var body: some View {
        VStack(spacing: 22) {
            header
            VStack(spacing: 10) {
                ForEach(AIPermission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: model.status(of: permission),
                        isBusy: model.busy == permission,
                        onAllow: { Task { await model.request(permission) } },
                        onOpenSettings: { PermissionProbe.openSettings(for: permission) })
                }
            }
            footer
        }
        .padding(.horizontal, 34)
        .padding(.top, 38)
        .padding(.bottom, 26)
        .frame(width: 640)
        .tint(accent)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Get Wisp ready for AI")
                .font(.system(size: 26, weight: .bold))
            Text("AI agents running in Wisp use these permissions to see the screen, control apps and reach your files. Allow them once now so work never stops halfway.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.needsRelaunch {
            VStack(spacing: 10) {
                Text("Screen Recording starts working after Wisp restarts. Restart now, before you begin work.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Later", action: onDone)
                        .controlSize(.large)
                    Button("Restart Wisp") { model.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            Button(action: onDone) {
                Text(model.allRequiredGranted ? "All set — Start" : "Continue without the rest")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// One permission: what it is for, its live status, and the action that asks for it.
private struct PermissionRow: View {
    let permission: AIPermission
    let status: PermissionStatus
    let isBusy: Bool
    let onAllow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: permission.symbol)
                .font(.system(size: 18))
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.system(size: 14, weight: .semibold))
                    if !permission.isRequired {
                        Text("Optional").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Text(permission.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)
        case .needsRelaunch:
            Label("Restart needed", systemImage: "arrow.clockwise.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        case .denied:
            Button("Open Settings", action: onOpenSettings)
        case .notDetermined:
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Window controller

/// Hosts ``AIPermissionsView`` in its own window, shared so the Help menu can reopen it.
final class AIPermissionsController: NSWindowController {
    static let shared = AIPermissionsController()

    private let model = AIPermissionsModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = AIPermissionsView(model: model, onDone: { [weak window] in window?.performClose(nil) })
        window.contentViewController = NSHostingController(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// macOS can drop a grant later (a reset, a different build). Each time Wisp comes to the
    /// front, re-check and bring the window back if a permission that worked is gone.
    func watchForLostPermissions() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.showIfPermissionLost() }
        }
    }

    @MainActor
    private func showIfPermissionLost() async {
        guard window?.isVisible != true else { return }
        let hadAll = model.allRequiredGranted
        await model.refresh()
        if hadAll, !model.allRequiredGranted { show() }
    }

    /// Checks the required permissions and opens the window only when one is missing.
    @MainActor
    func showIfAnyRequiredMissing() async {
        await model.refresh()
        guard !model.allRequiredGranted else { return }
        show()
    }
}
