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
        guard seconds > 0 else { return "now" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Loads and refreshes the Claude usage snapshot for the HUD. Used on the main thread.
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var loadError: String?

    /// `~/.claude/cache/statusline-usage.json`.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cache/statusline-usage.json")

    func reload() {
        do {
            let data = try Data(contentsOf: Self.fileURL)
            snapshot = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
            lastLoaded = Date()
            loadError = nil
        } catch CocoaError.fileReadNoSuchFile {
            loadError = "No usage data yet — run Claude Code once to generate it."
        } catch {
            loadError = "Couldn't read usage: \(error.localizedDescription)"
        }
    }
}
