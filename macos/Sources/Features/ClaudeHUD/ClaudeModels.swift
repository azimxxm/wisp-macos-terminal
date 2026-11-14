import Foundation
import Combine

/// Claude Code's OAuth login, shared by the usage and model calls.
enum ClaudeAuth {
    enum AuthError: Error { case noToken }

    /// Claude Code keeps its OAuth login in the Keychain ("Claude Code-credentials"), or in
    /// `~/.claude/.credentials.json` on older installs. Asking through `/usr/bin/security`
    /// matches what the status line does, so macOS doesn't show an extra Keychain prompt.
    /// Blocking — call it off the main thread.
    static func accessToken() throws -> String {
        struct Credentials: Decodable {
            struct OAuth: Decodable { let accessToken: String? }
            let claudeAiOauth: OAuth?
        }

        var json = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            json = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        }
        if json.isEmpty {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            json = (try? Data(contentsOf: file)) ?? Data()
        }
        let credentials = try? JSONDecoder().decode(Credentials.self, from: json)
        guard let token = credentials?.claudeAiOauth?.accessToken, !token.isEmpty else { throw AuthError.noToken }
        return token
    }

    /// An authorized request to the Anthropic API with Claude Code's login.
    static func request(_ url: URL, timeout: TimeInterval) async throws -> URLRequest {
        let token = try await Task.detached { try accessToken() }.value
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }
}

/// One model as returned by `GET /v1/models`.
struct ClaudeModelInfo: Decodable, Identifiable {
    let id: String
    let displayName: String
    let createdAt: String
    let line: String?
    let lifecycle: String?
    let deprecatedAt: String?
    let maxInputTokens: Int?
    let efforts: [String]

    enum CodingKeys: String, CodingKey {
        case id, line, lifecycle, capabilities
        case displayName = "display_name"
        case createdAt = "created_at"
        case deprecatedAt = "deprecated_at"
        case maxInputTokens = "max_input_tokens"
    }

    /// `capabilities.effort` looks like `{"supported": true, "low": {"supported": true}, ...}`.
    private struct Capabilities: Decodable {
        let effort: [String: Flag]?

        struct Flag: Decodable {
            let supported: Bool
            init(from decoder: Decoder) throws {
                if let object = try? decoder.container(keyedBy: Key.self) {
                    supported = (try? object.decode(Bool.self, forKey: .supported)) ?? false
                } else {
                    supported = (try? decoder.singleValueContainer().decode(Bool.self)) ?? false
                }
            }
            enum Key: String, CodingKey { case supported }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        line = try container.decodeIfPresent(String.self, forKey: .line)
        lifecycle = try container.decodeIfPresent(String.self, forKey: .lifecycle)
        deprecatedAt = try container.decodeIfPresent(String.self, forKey: .deprecatedAt)
        maxInputTokens = try container.decodeIfPresent(Int.self, forKey: .maxInputTokens)
        let capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        efforts = (capabilities?.effort ?? [:])
            .filter { $0.key != "supported" && $0.value.supported }
            .map(\.key)
    }

    /// "Claude Opus 5.5" → "Opus 5.5".
    var shortName: String {
        displayName.hasPrefix("Claude ") ? String(displayName.dropFirst("Claude ".count)) : displayName
    }

    /// The family ("opus", "sonnet", ...); falls back to the id's second word.
    var family: String {
        if let line, !line.isEmpty { return line }
        return id.split(separator: "-").dropFirst().first.map(String.init) ?? id
    }
}

/// The newest model of each family, straight from Anthropic, so the HUD never shows stale
/// names. Cached for an hour in `~/.claude/cache/wisp-models.json`.
@MainActor
final class ClaudeModelCatalog: ObservableObject {
    static let shared = ClaudeModelCatalog()

    @Published private(set) var models: [ClaudeModelInfo] = []

    /// Families Claude Code understands as `/model` aliases, in the order we show them.
    static let aliasFamilies = ["fable", "opus", "sonnet", "haiku"]
    static let effortOrder = ["low", "medium", "high", "xhigh", "max"]

    private static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=100")
    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cache/wisp-models.json")
    private static let cacheLifetime: TimeInterval = 3600
    private static let requestTimeout: TimeInterval = 8

    private var isRefreshing = false

    /// Effort levels any shown model supports, in the usual order.
    var efforts: [String] {
        let supported = Set(models.flatMap(\.efforts))
        return supported.isEmpty ? Self.effortOrder : Self.effortOrder.filter(supported.contains)
    }

    func reload() {
        if models.isEmpty, let data = try? Data(contentsOf: Self.cacheURL) { apply(data) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path)
        let age = (attributes?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > Self.cacheLifetime || models.isEmpty, !isRefreshing else { return }
        Task { await refresh() }
    }

    private func refresh() async {
        guard let url = Self.modelsURL else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let request = try await ClaudeAuth.request(url, timeout: Self.requestTimeout)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, apply(data) else { return }
            try? data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            // Offline or logged out: keep the cached list.
        }
    }

    /// Picks the newest active model per family. Returns false if the payload was unusable.
    @discardableResult
    private func apply(_ data: Data) -> Bool {
        struct Page: Decodable { let data: [ClaudeModelInfo] }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return false }

        let active = page.data.filter { ($0.lifecycle ?? "active") == "active" && $0.deprecatedAt == nil }
        var newest: [String: ClaudeModelInfo] = [:]
        for model in active where (newest[model.family]?.createdAt ?? "") < model.createdAt {
            newest[model.family] = model
        }
        let known = Self.aliasFamilies.compactMap { newest[$0] }
        let others = newest.values.filter { !Self.aliasFamilies.contains($0.family) }.sorted { $0.family < $1.family }
        guard !known.isEmpty || !others.isEmpty else { return false }
        models = known + others
        return true
    }
}

/// What Claude Code records about a running session (`~/.claude/sessions/<pid>.json`).
enum ClaudeSession {
    private struct Record: Decodable {
        let sessionId: String?
        let cwd: String?
        let status: String?
    }

    private static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private static let transcriptTailBytes = 256 * 1024

    private static func record(pid: Int) -> Record? {
        let file = claudeDir.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// "busy" while Claude works on a turn, "idle" otherwise (as Claude Code reports it).
    static func status(pid: Int) -> String? { record(pid: pid)?.status }

    /// The model id the session last answered with, read from the end of its transcript.
    static func activeModelID(pid: Int) -> String? {
        guard let session = record(pid: pid), let id = session.sessionId else { return nil }
        guard let transcript = transcriptURL(sessionID: id, cwd: session.cwd),
              let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0)
        guard let data = try? handle.readToEnd(), let text = String(bytes: data, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #""model":"(claude-[a-z0-9-]+)""#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let range = Range(last.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Claude Code stores transcripts in `projects/<cwd with non-alphanumerics as ->/<id>.jsonl`.
    private static func transcriptURL(sessionID: String, cwd: String?) -> URL? {
        let projects = claudeDir.appendingPathComponent("projects")
        if let cwd {
            let folder = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            let url = projects.appendingPathComponent("\(folder)/\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders
            .map { projects.appendingPathComponent("\($0)/\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
