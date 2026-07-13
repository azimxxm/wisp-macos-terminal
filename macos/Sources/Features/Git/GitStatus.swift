import Foundation
import Combine

/// Resolves the `git` binary to use for read-only status queries, preferring Homebrew then the
/// system shim. Cached because the location never changes during a run.
enum GitBinary {
    static let path: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()
}

/// Runs read-only `git` queries synchronously. Never call from the main thread — each call spawns
/// a subprocess and blocks until it exits. All actual repo mutations happen in the user's terminal,
/// not here; this type only reads state for the status bar.
enum Git {
    /// Runs `git -C <cwd> <args>` and returns its stdout plus exit code, or nil if the process could
    /// not be launched. stderr is discarded — a non-repo directory is a normal, expected outcome.
    static func run(_ args: [String], in cwd: URL) -> (out: String, code: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitBinary.path)
        process.arguments = ["-C", cwd.path] + args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before wait so a large output filling the pipe buffer can't deadlock the child.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}

/// A snapshot of a repository's state, shown in the Warp-style git status bar.
struct GitStatus: Equatable {
    var branch: String
    var isDetached: Bool = false
    var hasUpstream: Bool = false
    var ahead: Int = 0
    var behind: Int = 0
    var staged: Int = 0
    var unstaged: Int = 0
    var untracked: Int = 0
    var conflicted: Int = 0
    var insertions: Int = 0
    var deletions: Int = 0
    /// Local branch names, for the checkout / merge menus.
    var localBranches: [String] = []

    /// Tracked changes plus conflicts. Untracked files are counted separately since they're noisier.
    var changedCount: Int { staged + unstaged + conflicted }
    var isClean: Bool { changedCount == 0 && untracked == 0 }
}

extension GitStatus {
    /// Reads the repository rooted at (or above) `cwd`. Returns nil when `cwd` is not inside a git
    /// work tree — the caller hides the status bar in that case.
    static func load(cwd: URL) -> GitStatus? {
        guard let res = Git.run(["status", "--porcelain=v2", "--branch"], in: cwd),
              res.code == 0,
              res.out.contains("# branch.") else { return nil }

        var status = GitStatus(branch: "")
        var oid = ""

        for raw in res.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                if name == "(detached)" {
                    status.isDetached = true
                } else {
                    status.branch = name
                }
            } else if line.hasPrefix("# branch.upstream ") {
                status.hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                for token in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if token.hasPrefix("+") {
                        status.ahead = Int(token.dropFirst()) ?? 0
                    } else if token.hasPrefix("-") {
                        status.behind = Int(token.dropFirst()) ?? 0
                    }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // Changed/renamed entry: field 2 is the two-char <XY> staged/unstaged state.
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                if fields.count >= 2 {
                    let xy = Array(fields[1])
                    if xy.count == 2 {
                        if xy[0] != "." { status.staged += 1 }
                        if xy[1] != "." { status.unstaged += 1 }
                    }
                }
            } else if line.hasPrefix("u ") {
                status.conflicted += 1
            } else if line.hasPrefix("? ") {
                status.untracked += 1
            }
        }

        if status.isDetached {
            status.branch = oid.isEmpty ? "detached" : String(oid.prefix(7))
        }

        // Line-level +/- against HEAD (tracked changes only; matches Warp's prompt diff stat).
        if let diff = Git.run(["diff", "--shortstat", "HEAD"], in: cwd), diff.code == 0 {
            let parsed = parseShortstat(diff.out)
            status.insertions = parsed.insertions
            status.deletions = parsed.deletions
        }

        if let branches = Git.run(["branch", "--format=%(refname:short)"], in: cwd), branches.code == 0 {
            status.localBranches = branches.out
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        return status
    }

    /// Parses `git diff --shortstat` output, e.g. " 3 files changed, 72 insertions(+), 63 deletions(-)".
    private static func parseShortstat(_ text: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0
        for part in text.components(separatedBy: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.contains("insertion") {
                insertions = leadingInt(token)
            } else if token.contains("deletion") {
                deletions = leadingInt(token)
            }
        }
        return (insertions, deletions)
    }

    private static func leadingInt(_ s: String) -> Int {
        Int(s.prefix { $0.isNumber }) ?? 0
    }
}

/// Watches the focused terminal's working directory and republishes its git state for the status
/// bar. Polls on a timer while inside a repo, and can be nudged to refresh right after an action is
/// sent to the terminal. Main-actor isolated; the blocking git calls run on a detached task.
@MainActor
final class GitRepositoryMonitor: ObservableObject {
    @Published private(set) var status: GitStatus?

    private var cwd: URL?
    private var timer: Timer?
    private var inFlight = false
    /// Bumped on every refresh so a slow, superseded result can be discarded.
    private var generation = 0

    private static let pollInterval: TimeInterval = 5

    /// Points the monitor at a new working directory (or nil) and refreshes immediately. A no-op if
    /// the directory hasn't actually changed, so it's safe to call from `onAppear` and `onChange`.
    func activate(cwd: URL?) {
        guard self.cwd != cwd else { return }
        self.cwd = cwd
        refresh(force: true)
    }

    /// Re-reads git state. `force` bypasses the in-flight guard, used on directory change and after
    /// an action so a running poll can't swallow the refresh.
    func refresh(force: Bool = false) {
        guard let cwd else {
            status = nil
            stopTimer()
            return
        }
        if inFlight && !force { return }
        inFlight = true
        generation &+= 1
        let gen = generation
        let dir = cwd
        Task.detached(priority: .utility) { [weak self] in
            let newStatus = GitStatus.load(cwd: dir)
            await self?.apply(newStatus, generation: gen)
        }
    }

    /// Applies a freshly-loaded status on the main actor, discarding it if a newer refresh has
    /// already started. Also starts/stops the poll timer based on whether we're inside a repo.
    private func apply(_ newStatus: GitStatus?, generation gen: Int) {
        inFlight = false
        guard gen == generation else { return } // a newer refresh already superseded us
        if status != newStatus { status = newStatus }
        if newStatus == nil { stopTimer() } else { startTimer() }
    }

    /// Refresh shortly after an action is sent to the terminal, giving the command time to run.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refresh(force: true)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
