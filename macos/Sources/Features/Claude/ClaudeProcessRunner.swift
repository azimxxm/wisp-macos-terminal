import Foundation
import Combine

/// Runs a shell command and streams its combined stdout/stderr into `output` live, so the Claude
/// panel can show setup/update/git scripts running in real time. Used on the main thread.
final class ClaudeProcessRunner: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastExitCode: Int32?

    private var process: Process?

    /// Runs a command line through `bash -lc` so scripts, pipes, `cd`, and a login PATH all work.
    func runBash(_ command: String, cwd: URL? = nil) {
        run(launchPath: "/bin/bash", arguments: ["-lc", command], cwd: cwd)
    }

    func run(launchPath: String, arguments: [String], cwd: URL? = nil) {
        guard !isRunning else { return }
        output = ""
        isRunning = true
        lastExitCode = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        // Ensure Homebrew / node / etc. are discoverable even when launched from the GUI, where
        // the inherited PATH is minimal.
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.output += chunk }
        }
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.isRunning = false
                self?.lastExitCode = code
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            output += "Failed to launch: \(error.localizedDescription)\n"
            isRunning = false
        }
    }

    func stop() {
        process?.terminate()
    }
}
