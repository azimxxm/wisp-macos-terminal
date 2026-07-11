import SwiftUI
import AppKit

/// The "Claude" Settings panel: a GUI over the user's `claude-agents` repo — run the installer,
/// pull git updates, and browse profiles / skills / agents — instead of remembering shell flags.
struct ClaudePanelView: View {
    @AppStorage("com.azimxxm.wisp.claude.repoPath") private var repoPath = "~/Documents/claude-agents"
    @StateObject private var runner = ClaudeProcessRunner()
    @State private var tab: Tab = .setup

    private enum Tab: String, CaseIterable, Identifiable {
        case setup = "Setup"
        case profiles = "Profiles"
        case library = "Library"
        var id: String { rawValue }
    }

    private var repoURL: URL {
        URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
    }
    private var repoExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: repoURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch tab {
            case .setup:
                ClaudeSetupTab(repoURL: repoURL, repoExists: repoExists, runner: runner, onChooseRepo: chooseRepo)
            case .profiles:
                ClaudeBrowserTab(repoURL: repoURL, repoExists: repoExists, kind: .profiles)
            case .library:
                ClaudeBrowserTab(repoURL: repoURL, repoExists: repoExists, kind: .library)
            }
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select claude-agents"
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }
}

// MARK: - Setup tab

private struct ClaudeSetupTab: View {
    let repoURL: URL
    let repoExists: Bool
    @ObservedObject var runner: ClaudeProcessRunner
    let onChooseRepo: () -> Void

    @AppStorage("com.azimxxm.wisp.claude.autonomous") private var autonomous = false
    @AppStorage("com.azimxxm.wisp.claude.allowPush") private var allowPush = false
    @AppStorage("com.azimxxm.wisp.claude.allowSudo") private var allowSudo = false
    @AppStorage("com.azimxxm.wisp.claude.allowServer") private var allowServer = false

    private var setupCommand: String {
        var parts = ["bash setup.sh", autonomous ? "autonomous" : "normal", "--yes"]
        if allowPush { parts.append("--allow-push") }
        if allowSudo { parts.append("--allow-sudo") }
        if allowServer { parts.append("--allow-server") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            repoRow

            if repoExists {
                HStack(spacing: 10) {
                    Toggle("Autonomous", isOn: $autonomous)
                    Spacer()
                    Toggle("push", isOn: $allowPush)
                    Toggle("sudo", isOn: $allowSudo)
                    Toggle("server", isOn: $allowServer)
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 8) {
                    actionButton("Run Setup", "arrow.down.circle") { runner.runBash(setupCommand, cwd: repoURL) }
                    actionButton("Update", "arrow.triangle.2.circlepath") { runner.runBash("bash update.sh", cwd: repoURL) }
                    actionButton("Doctor", "stethoscope") { runner.runBash("bash doctor.sh", cwd: repoURL) }
                }

                HStack(spacing: 8) {
                    actionButton("Check Updates", "magnifyingglass") {
                        runner.runBash(
                            "git fetch --quiet && git status -sb && echo && echo 'Commits behind upstream:' && "
                            + "(git log --oneline HEAD..@{u} 2>/dev/null || echo '(no upstream configured)')",
                            cwd: repoURL)
                    }
                    actionButton("Update Now (git pull)", "square.and.arrow.down.on.square") {
                        runner.runBash("git pull --ff-only && bash update.sh", cwd: repoURL)
                    }
                }

                Text("Runs: `\(setupCommand)`")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                ClaudeConsole(runner: runner)
            } else {
                missingRepo
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var repoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: repoExists ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(repoExists ? Color.secondary : Color.orange)
            Text(repoURL.path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: onChooseRepo)
        }
    }

    private var missingRepo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("claude-agents repo not found at that path.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Choose the folder, or clone it first:")
                .font(.caption).foregroundStyle(.secondary)
            Text("git clone <your-claude-agents-repo> ~/Documents/claude-agents")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }

    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .disabled(runner.isRunning)
    }
}

// MARK: - Console

private struct ClaudeConsole: View {
    @ObservedObject var runner: ClaudeProcessRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { runner.stop() }.controlSize(.small)
                } else if let code = runner.lastExitCode {
                    Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(code == 0 ? .green : .red)
                    Text(code == 0 ? "Done" : "Exited with code \(code)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.output.isEmpty ? "Output will appear here." : runner.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: runner.output) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 180)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - Profiles / Library browser

private struct ClaudeBrowserTab: View {
    let repoURL: URL
    let repoExists: Bool
    let kind: Kind

    enum Kind { case profiles, library }

    @State private var profiles: [ClaudeRepo.Item] = []
    @State private var skills: [ClaudeRepo.Item] = []
    @State private var agents: [ClaudeRepo.Item] = []
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter…", text: $query).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .padding(12)

            Divider()

            List {
                if !repoExists {
                    Text("Select the claude-agents repo in the Setup tab.")
                        .foregroundStyle(.secondary)
                } else if kind == .profiles {
                    section("Profiles", items: filter(profiles))
                } else {
                    section("Skills", items: filter(skills))
                    section("Agents", items: filter(agents))
                }
            }
            .listStyle(.inset)
        }
        .task(id: repoURL.path) { await load() }
    }

    @ViewBuilder
    private func section(_ title: String, items: [ClaudeRepo.Item]) -> some View {
        Section(header: Text("\(title) (\(items.count))")) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                    }
                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func filter(_ items: [ClaudeRepo.Item]) -> [ClaudeRepo.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private func load() async {
        let repo = repoURL
        let loaded = await Task.detached(priority: .userInitiated) {
            (ClaudeRepo.profiles(in: repo), ClaudeRepo.skills(in: repo), ClaudeRepo.agents(in: repo))
        }.value
        profiles = loaded.0
        skills = loaded.1
        agents = loaded.2
    }
}

// MARK: - Repo reading

enum ClaudeRepo {
    struct Item: Identifiable, Hashable {
        let name: String
        let description: String
        let url: URL
        var id: URL { url }
    }

    static func profiles(in repo: URL) -> [Item] {
        let dir = repo.appendingPathComponent("profiles")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { Item(name: $0.deletingPathExtension().lastPathComponent, description: "", url: $0) }
            .sorted { $0.name < $1.name }
    }

    static func agents(in repo: URL) -> [Item] {
        let dir = repo.appendingPathComponent("agents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.map { file in
            let meta = frontmatter(of: file)
            return Item(name: meta.name ?? file.deletingPathExtension().lastPathComponent,
                        description: meta.description ?? "",
                        url: file)
        }.sorted { $0.name < $1.name }
    }

    static func skills(in repo: URL) -> [Item] {
        let dir = repo.appendingPathComponent("skills")
        let subdirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return subdirs.compactMap { sub -> Item? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let skillFile = sub.appendingPathComponent("SKILL.md")
            let meta = frontmatter(of: skillFile)
            return Item(name: meta.name ?? sub.lastPathComponent,
                        description: meta.description ?? "",
                        url: skillFile)
        }.sorted { $0.name < $1.name }
    }

    /// Extracts `name:` and `description:` from a file's leading `--- … ---` YAML frontmatter.
    private static func frontmatter(of file: URL) -> (name: String?, description: String?) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return (nil, nil) }
        var name: String?
        var description: String?
        var delimiters = 0
        for line in content.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                delimiters += 1
                if delimiters >= 2 { break }
                continue
            }
            guard delimiters == 1 else { continue }
            if name == nil { name = value(of: "name", in: line) }
            if description == nil { description = value(of: "description", in: line) }
        }
        return (name, description)
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
