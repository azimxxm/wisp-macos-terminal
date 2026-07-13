import SwiftUI

extension Notification.Name {
    /// Posted by the titlebar git button / View menu item to show or hide the git status bar.
    static let wispToggleGitBar = Notification.Name("com.azimxxm.wisp.toggleGitBar")
}

/// A Warp-style status bar shown at the bottom of the terminal when the working directory is a git
/// repository. Displays the branch, ahead/behind, dirty counts and line diff, and offers one-click
/// buttons for the everyday git commands (stage, commit, push, pull, fetch, checkout, merge, stash,
/// …). Actions are typed into the focused terminal so they run in the user's own shell/git config
/// and show up in scrollback, exactly like typing them by hand.
struct GitStatusBarView: View {
    let status: GitStatus
    /// Runs a shell command in the focused terminal (the caller appends the return key & refreshes).
    let run: (String) -> Void
    let onRefresh: () -> Void
    let onHide: () -> Void

    @State private var showCommit = false
    @State private var showNewBranch = false

    private var otherBranches: [String] {
        status.localBranches.filter { $0 != status.branch }
    }

    var body: some View {
        HStack(spacing: 8) {
            branchMenu
            aheadBehind
            dirtyIndicator
            Spacer(minLength: 8)
            actions
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Branch

    private var branchMenu: some View {
        Menu {
            ForEach(status.localBranches, id: \.self) { branch in
                Button {
                    run("git checkout \(GitShell.quote(branch))")
                } label: {
                    Label(branch, systemImage: branch == status.branch ? "checkmark" : "arrow.triangle.branch")
                }
                .disabled(branch == status.branch)
            }

            Divider()
            Button("New Branch…") { openLater($showNewBranch) }

            if !otherBranches.isEmpty {
                Menu("Merge into \(status.branch)") {
                    ForEach(otherBranches, id: \.self) { branch in
                        Button(branch) { run("git merge \(GitShell.quote(branch))") }
                    }
                }
            }

            Divider()
            Button("Fetch") { run("git fetch") }
            Button("Pull") { run("git pull") }
            Button("Push") { run("git push") }
        } label: {
            pill {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(status.branch)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Branch: \(status.branch)")
        .popover(isPresented: $showNewBranch, arrowEdge: .bottom) {
            TextInputPopover(
                title: "New Branch",
                placeholder: "branch-name",
                confirmTitle: "Create",
                dismiss: { showNewBranch = false },
                onConfirm: { name in run("git checkout -b \(GitShell.quote(name))") }
            )
        }
    }

    // MARK: Status readout

    @ViewBuilder
    private var aheadBehind: some View {
        if status.hasUpstream, status.ahead > 0 || status.behind > 0 {
            HStack(spacing: 5) {
                if status.ahead > 0 { Text("↑\(status.ahead)") }
                if status.behind > 0 { Text("↓\(status.behind)") }
            }
            .foregroundStyle(.secondary)
        } else if !status.hasUpstream, !status.isDetached {
            Text("no upstream")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var dirtyIndicator: some View {
        if status.isClean {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                Text("clean")
            }
            .foregroundStyle(.green.opacity(0.9))
        } else {
            HStack(spacing: 6) {
                if status.changedCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("\(status.changedCount)")
                    }
                    .help("\(status.staged) staged · \(status.unstaged) unstaged")
                }
                if status.conflicted > 0 {
                    Text("⚠\(status.conflicted)").foregroundStyle(.red).help("Conflicts")
                }
                if status.untracked > 0 {
                    Text("?\(status.untracked)").foregroundStyle(.secondary).help("Untracked files")
                }
                if status.insertions > 0 { Text("+\(status.insertions)").foregroundStyle(.green) }
                if status.deletions > 0 { Text("−\(status.deletions)").foregroundStyle(.red) }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 6) {
            pillButton("Stage", "plus.circle") { run("git add -A") }
                .disabled(status.isClean)

            pillButton("Commit", "checkmark.seal") { showCommit = true }
                .popover(isPresented: $showCommit, arrowEdge: .bottom) {
                    CommitPopover(
                        defaultStageAll: !status.isClean,
                        dismiss: { showCommit = false },
                        onCommit: { message, stageAll, push in
                            var command = stageAll ? "git add -A && " : ""
                            command += "git commit -m \(GitShell.quote(message))"
                            if push { command += " && git push" }
                            run(command)
                        }
                    )
                }

            pillButton("Push", "arrow.up") { run("git push") }
                .disabled(status.hasUpstream && status.ahead == 0 && status.isClean)

            Menu {
                Button("Pull") { run("git pull") }
                Button("Fetch") { run("git fetch") }
                Divider()
                Button("Stash") { run("git stash push") }
                Button("Stash Pop") { run("git stash pop") }
                Divider()
                Button("Status") { run("git status") }
                Button("Log") { run("git log --oneline -20") }
                Divider()
                Button("Refresh", action: onRefresh)
                Button("Hide Git Bar", action: onHide)
            } label: {
                pill { Image(systemName: "ellipsis") }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Building blocks

    /// Wraps content in the shared rounded "pill" chrome used for every bar control.
    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
    }

    private func pillButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle())
        .help(title)
    }

    /// Opens a popover on the next runloop tick so the enclosing menu has finished dismissing first
    /// (setting the flag synchronously from a menu action can drop the popover on macOS).
    private func openLater(_ flag: Binding<Bool>) {
        DispatchQueue.main.async { flag.wrappedValue = true }
    }
}

/// Pressable pill styling for the bar's action buttons.
private struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color.secondary.opacity(configuration.isPressed ? 0.28 : 0.12),
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Commit popover

/// Small popover to enter a commit message and commit (optionally staging everything and pushing).
private struct CommitPopover: View {
    let defaultStageAll: Bool
    let dismiss: () -> Void
    let onCommit: (_ message: String, _ stageAll: Bool, _ push: Bool) -> Void

    @State private var message = ""
    @State private var stageAll: Bool

    init(defaultStageAll: Bool, dismiss: @escaping () -> Void,
         onCommit: @escaping (String, Bool, Bool) -> Void) {
        self.defaultStageAll = defaultStageAll
        self.dismiss = dismiss
        self.onCommit = onCommit
        _stageAll = State(initialValue: defaultStageAll)
    }

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit").font(.headline)

            TextField("Message", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { commit(push: false) }

            Toggle("Stage all changes first (git add -A)", isOn: $stageAll)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            HStack {
                Spacer()
                Button("Commit & Push") { commit(push: true) }
                    .disabled(trimmed.isEmpty)
                Button("Commit") { commit(push: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
    }

    private func commit(push: Bool) {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed, stageAll, push)
        dismiss()
    }
}

// MARK: - Text input popover

/// A minimal single-field popover used for actions that need one string (e.g. a new branch name).
private struct TextInputPopover: View {
    let title: String
    let placeholder: String
    let confirmTitle: String
    let dismiss: () -> Void
    let onConfirm: (String) -> Void

    @State private var text = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}

// MARK: - Shell quoting

enum GitShell {
    /// Single-quotes a string for safe injection into a shell command line, escaping embedded quotes.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
