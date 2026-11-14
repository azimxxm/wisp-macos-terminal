import Foundation
import Combine
import SwiftUI

/// Parsed contents of Claude's `~/.claude/cache/statusline-usage.json`, which Claude Code writes
/// with the same plan-usage data shown in Claude.app's "Plan usage limits" panel.
///
/// Only the fields Wisp displays are declared; unknown keys (experimental codenames, etc.) are
/// ignored by `Codable`.
struct ClaudeUsageSnapshot: Codable {
    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case extraUsage = "extra_usage"
    }

    /// A single plan limit (session, weekly, per-model weekly, …).
    struct Limit: Codable, Identifiable {
        let kind: String
        let group: String?
        let percent: Double
        let severity: String?
        let isActive: Bool?
        let resetsAtRaw: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case isActive = "is_active"
            case resetsAtRaw = "resets_at"
        }

        var id: String { kind }
        var resetsAt: Date? { ClaudeUsage.parseDate(resetsAtRaw) }

        /// A friendly title, using the scoped model name where present (e.g. "Weekly · Fable").
        var title: String {
            switch kind {
            case "session": return "Current session"
            case "weekly_all": return "Weekly · All models"
            case "weekly_scoped":
                if let model = scope?.model?.displayName { return "Weekly · \(model)" }
                return "Weekly · Scoped"
            default:
                return kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    /// The `scope` object attached to scoped limits.
    struct Scope: Codable {
        let model: ModelRef?

        struct ModelRef: Codable {
            let id: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
    }

    /// A rolling window (5-hour session or 7-day) with optional dollar accounting.
    struct Window: Codable {
        let utilization: Double?
        let resetsAtRaw: String?
        let limitDollars: Double?
        let usedDollars: Double?
        let remainingDollars: Double?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAtRaw = "resets_at"
            case limitDollars = "limit_dollars"
            case usedDollars = "used_dollars"
            case remainingDollars = "remaining_dollars"
        }

        var resetsAt: Date? { ClaudeUsage.parseDate(resetsAtRaw) }
    }

    /// Pay-as-you-go "extra usage" accounting.
    struct ExtraUsage: Codable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization, currency
        }
    }
}

/// Helpers for parsing and formatting Claude usage data.
enum ClaudeUsage {
    /// Parses an ISO-8601 timestamp with optional fractional seconds.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// A short "2h 40m" / "40m" countdown from now until `date`.
    static func countdown(to date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        // A reset in the past means the cached numbers are stale; don't show "now" forever.
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Loads the Claude usage snapshot for the HUD. Shows the cached file right away, then asks
/// Anthropic's usage endpoint for live numbers (the same call Claude Code's status line makes) and
/// writes them back to the cache so the status line benefits too. Used on the main thread.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    /// When the shown numbers were fetched from Anthropic (not when the file was read).
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var loadError: String?
    @Published private(set) var isRefreshing = false
    /// Set when the live refresh failed and older cached numbers are shown.
    @Published private(set) var liveError: String?

    /// `~/.claude/cache/statusline-usage.json`.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cache/statusline-usage.json")

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")
    /// Don't hit the endpoint more than this often; it rate-limits (429) aggressively.
    private static let minLiveInterval: TimeInterval = 30
    private static let rateLimitBackoff: TimeInterval = 300
    private static let requestTimeout: TimeInterval = 8

    private var lastLiveAttempt: Date?
    private var backoffUntil: Date?

    /// Called whenever the HUD opens or the refresh button is pressed.
    func reload(force: Bool = false) {
        loadCache()
        Task { await refreshLive(force: force) }
    }

    private func loadCache() {
        do {
            let data = try Data(contentsOf: Self.fileURL)
            snapshot = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
            let attributes = try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)
            lastLoaded = attributes?[.modificationDate] as? Date
            loadError = nil
        } catch CocoaError.fileReadNoSuchFile {
            loadError = "No usage data yet — fetching…"
        } catch {
            loadError = "Couldn't read usage: \(error.localizedDescription)"
        }
    }

    private func refreshLive(force: Bool) async {
        let now = Date()
        if let backoffUntil, now < backoffUntil { return }
        if !force, let lastLiveAttempt, now.timeIntervalSince(lastLiveAttempt) < Self.minLiveInterval { return }
        guard !isRefreshing else { return }
        lastLiveAttempt = now
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let data = try await Self.fetchUsage()
            let fresh = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
            guard fresh.limits?.isEmpty == false || fresh.sevenDay?.utilization != nil else {
                throw UsageError.unexpectedResponse
            }
            snapshot = fresh
            lastLoaded = Date()
            loadError = nil
            liveError = nil
            try? data.write(to: Self.fileURL, options: .atomic)
        } catch UsageError.rateLimited {
            backoffUntil = Date().addingTimeInterval(Self.rateLimitBackoff)
            liveError = "Rate limited — showing cached numbers"
        } catch {
            liveError = "Offline — showing cached numbers"
        }
    }

    private enum UsageError: Error {
        case noToken, rateLimited, badStatus(Int), unexpectedResponse
    }

    private static func fetchUsage() async throws -> Data {
        guard let url = usageURL else { throw UsageError.unexpectedResponse }
        let token = try await Task.detached { try readAccessToken() }.value
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw UsageError.rateLimited }
        guard status == 200 else { throw UsageError.badStatus(status) }
        return data
    }

    /// Claude Code keeps its OAuth login in the Keychain ("Claude Code-credentials"), or in
    /// `~/.claude/.credentials.json` on older installs. Asking through `/usr/bin/security`
    /// matches what the status line does, so macOS doesn't show an extra Keychain prompt.
    nonisolated private static func readAccessToken() throws -> String {
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
        guard let token = credentials?.claudeAiOauth?.accessToken, !token.isEmpty else { throw UsageError.noToken }
        return token
    }
}
