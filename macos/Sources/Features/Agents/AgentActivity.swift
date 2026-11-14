import AppKit
import Combine
import Darwin
import IOKit.pwr_mgt
import GhosttyKit

/// What an AI agent in a terminal is doing right now.
enum AgentState: String {
    /// The agent is producing output / thinking (it reports progress via OSC 9;4).
    case working
    /// The agent rang the bell or sent a notification and nobody has looked yet.
    case waiting
    /// An agent is running but quiet.
    case idle
}

/// One terminal that has an AI agent (Claude Code, Codex, ...) in the foreground.
struct AgentEntry: Identifiable {
    let id: UUID
    let agentName: String
    let title: String
    let workingDirectory: String
    let state: AgentState
    weak var surfaceView: Ghostty.SurfaceView?
}

/// Tracks per-terminal facts the core does not keep for us: the exit code of the last command,
/// how many commands finished (so scripts can wait for "the next one"), and whether an agent is
/// waiting for the user. Also keeps the Mac awake while any agent is working.
@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()

    /// Process names we treat as AI agents.
    static let knownAgents = ["claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose", "qwen"]

    @Published private(set) var agents: [AgentEntry] = []

    private var finishedCommands: [UUID: Int] = [:]
    private var lastExitCodes: [UUID: Int] = [:]
    private var waiting: Set<UUID> = []
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var observers: [NSObjectProtocol] = []
    private static let scanInterval: TimeInterval = 1

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyBellDidRing, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            MainActor.assumeIsolated { self?.attentionRequested(by: view) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    // MARK: - Events from the core

    func commandFinished(_ view: Ghostty.SurfaceView, exitCode: Int) {
        finishedCommands[view.id, default: 0] += 1
        lastExitCodes[view.id] = exitCode
    }

    /// Bell or desktop notification: the agent wants the user. Ignored while the user is looking.
    func attentionRequested(by view: Ghostty.SurfaceView) {
        guard !isLookedAt(view) else { return }
        waiting.insert(view.id)
        NSApp.requestUserAttention(.informationalRequest)
        scan()
    }

    // MARK: - Queries (used by AppleScript and the agents panel)

    func finishedCommandCount(_ view: Ghostty.SurfaceView) -> Int { finishedCommands[view.id] ?? 0 }

    /// -1 when no command has finished yet (or the shell did not report an exit code).
    func lastExitCode(_ view: Ghostty.SurfaceView) -> Int { lastExitCodes[view.id] ?? -1 }

    func agentName(for view: Ghostty.SurfaceView) -> String? {
        guard let pid = view.surfaceModel?.foregroundPID else { return nil }
        let name = Self.processName(pid: pid).lowercased()
        return Self.knownAgents.first { name == $0 || name.hasPrefix($0 + "-") }
    }

    func state(of view: Ghostty.SurfaceView) -> AgentState {
        if waiting.contains(view.id) { return .waiting }
        if let report = view.progressReport, report.state != .remove { return .working }
        return .idle
    }

    // MARK: - Scanning

    private func scan() {
        let views = NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { $0.surfaceTree.root?.leaves() ?? [] }

        // Looking at a terminal answers whatever it was waiting for.
        for view in views where waiting.contains(view.id) && isLookedAt(view) {
            waiting.remove(view.id)
        }

        let entries = views.compactMap { view -> AgentEntry? in
            guard let name = agentName(for: view) else { return nil }
            return AgentEntry(
                id: view.id, agentName: name, title: view.title,
                workingDirectory: view.pwd ?? "", state: state(of: view), surfaceView: view)
        }
        agents = entries
        updateDockBadge(entries)
        updateSleepAssertion(keepAwake: entries.contains { $0.state == .working })
    }

    private func isLookedAt(_ view: Ghostty.SurfaceView) -> Bool {
        NSApp.isActive && view.focused && (view.window?.isKeyWindow ?? false)
    }

    private func updateDockBadge(_ entries: [AgentEntry]) {
        let count = entries.filter { $0.state == .waiting }.count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Keeps the Mac from idle-sleeping while an agent works; released as soon as none does.
    private func updateSleepAssertion(keepAwake: Bool) {
        if keepAwake, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "An AI agent is working in Wisp" as CFString,
                &sleepAssertion)
        } else if !keepAwake, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    private static func processName(pid: Int) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}

extension Ghostty.SurfaceView {
    /// Output of the last finished command, using the shell-integration prompt marks.
    /// nil when the shell has no integration or no command has finished yet.
    func readLastCommandOutput() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_last_command_output(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}
