import SwiftUI

/// Settings → Permissions: the same live permission list as the "Get Wisp ready for AI"
/// window, so it can always be found again after that window is closed.
struct PermissionsSettingsView: View {
    @StateObject private var model = AIPermissionsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI agents running in Wisp use these permissions to see the screen, control apps and reach your files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                ForEach(AIPermission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: model.status(of: permission),
                        isBusy: model.busy == permission,
                        onAllow: { Task { await model.request(permission) } },
                        onOpenSettings: { PermissionProbe.openSettings(for: permission) })
                }

                if model.needsRelaunch {
                    HStack {
                        Text("Screen Recording starts working after Wisp restarts.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Wisp") { model.relaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(20)
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}
