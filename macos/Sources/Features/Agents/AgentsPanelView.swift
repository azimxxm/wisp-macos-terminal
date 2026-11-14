import AppKit
import SwiftUI

/// Every AI agent running in Wisp at a glance: which one is working, which one is waiting for
/// you, and a click to jump to it.
struct AgentsPanelView: View {
    @ObservedObject var activity: AgentActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Agents", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if activity.agents.isEmpty {
                Text("No agents running. Start `claude`, `codex` or another agent in any tab and it shows up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(activity.agents) { entry in
                            AgentRow(entry: entry) { focus(entry) }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 220)
    }

    private var summary: String {
        let waiting = activity.agents.filter { $0.state == .waiting }.count
        let working = activity.agents.filter { $0.state == .working }.count
        return "\(working) working · \(waiting) waiting"
    }

    private func focus(_ entry: AgentEntry) {
        guard let view = entry.surfaceView,
              let controller = view.window?.windowController as? BaseTerminalController else { return }
        controller.focusSurface(view)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AgentRow: View {
    let entry: AgentEntry
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                stateBadge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.agentName).font(.system(size: 13, weight: .semibold))
                        Text(stateText).font(.system(size: 11)).foregroundStyle(stateColor)
                    }
                    Text(entry.title.isEmpty ? entry.workingDirectory : entry.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to this terminal")
    }

    @ViewBuilder
    private var stateBadge: some View {
        if entry.state == .working {
            ProgressView().controlSize(.small).frame(width: 16)
        } else {
            Circle().fill(stateColor).frame(width: 10, height: 10).frame(width: 16)
        }
    }

    private var stateText: String {
        switch entry.state {
        case .working: return "working"
        case .waiting: return "waiting for you"
        case .idle: return "idle"
        }
    }

    private var stateColor: Color {
        switch entry.state {
        case .working: return .blue
        case .waiting: return .orange
        case .idle: return .secondary
        }
    }
}

/// Floating utility window that hosts ``AgentsPanelView``.
final class AgentsPanelController: NSWindowController {
    static let shared = AgentsPanelController()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = "AI Agents"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.contentViewController = NSHostingController(rootView: AgentsPanelView(activity: AgentActivity.shared))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
