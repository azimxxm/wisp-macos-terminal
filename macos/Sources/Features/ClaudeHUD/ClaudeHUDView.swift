import SwiftUI

/// The Claude control popover: plan-usage limits (mirroring Claude.app's usage panel), plus a
/// GUI to switch the model and reasoning effort of the focused Claude session.
struct ClaudeHUDView: View {
    @ObservedObject var store: ClaudeUsageStore
    @ObservedObject var catalog: ClaudeModelCatalog = .shared

    /// Model id the focused Claude session last answered with (e.g. "claude-opus-5-5").
    var activeModelID: String?

    /// Sends text to the focused terminal surface (used to inject `/model` and `/effort`).
    var onSend: (String) -> Void

    private let accent = Color(red: 0.42, green: 0.56, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            usageSection
            Divider()
            modelSection
            Divider()
            effortSection
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            store.reload()
            catalog.reload()
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Plan usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        store.reload(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh usage")
                }
            }

            if let limits = store.snapshot?.limits, !limits.isEmpty {
                // The API only lists the 5-hour session limit while a session window is open.
                if !limits.contains(where: { $0.kind == "session" }) {
                    Text("Current session: not started — begins with your next message")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(limits) { limit in
                    usageRow(
                        title: limit.title,
                        percent: limit.percent,
                        severity: limit.severity,
                        isActive: limit.isActive ?? false,
                        resetsAt: limit.resetsAt)
                }
            } else if let error = store.loadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let extra = store.snapshot?.extraUsage, extra.isEnabled == true {
                extraUsageRow(extra)
            }

            if let loaded = store.lastLoaded {
                Text("Updated \(loaded.formatted(date: Calendar.current.isDateInToday(loaded) ? .omitted : .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let liveError = store.liveError {
                Label(liveError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func usageRow(title: String, percent: Double, severity: String?, isActive: Bool, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                if isActive {
                    Text("active")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(color(for: severity).opacity(0.18), in: Capsule())
                        .foregroundStyle(color(for: severity))
                }
                Spacer()
                Text("\(Int(percent))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(color(for: severity))
            if let reset = ClaudeUsage.countdown(to: resetsAt) {
                Text("Resets in \(reset)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func extraUsageRow(_ extra: ClaudeUsageSnapshot.ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Extra usage")
                    .font(.system(size: 13))
                Spacer()
                if let used = extra.usedCredits, let limit = extra.monthlyLimit, limit > 0 {
                    Text("\(used, specifier: "%.2f") / \(limit, specifier: "%.0f") \(extra.currency ?? "")")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let util = extra.utilization {
                ProgressView(value: min(max(util / 100, 0), 1)).tint(accent)
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Model", systemImage: "cpu")
                .font(.system(size: 14, weight: .semibold))
            Text("Switches the focused Claude session")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            ForEach(modelChoices) { model in
                Button {
                    onSend("/model \(model.command)\r")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.symbol)
                            .frame(width: 20)
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name).font(.system(size: 13, weight: .medium))
                            Text(model.hint).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(accent)
                                .help("This session is using it")
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Effort

    private var effortSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Effort", systemImage: "dial.medium")
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(catalog.efforts, id: \.self) { effort in
                    Button {
                        onSend("/effort \(effort)\r")
                    } label: {
                        Text(effort)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private func color(for severity: String?) -> Color {
        switch severity {
        case "warning", "warn": return .orange
        case "critical", "high", "severe", "exceeded": return .red
        default: return accent
        }
    }

    // MARK: - Static data

    private struct ModelChoice: Identifiable {
        let name: String
        let command: String
        let hint: String
        let symbol: String
        let isActive: Bool
        var id: String { command }
    }

    /// Built from Anthropic's model list (newest per family). `command` is the family alias
    /// for Claude Code's `/model`, so it always resolves to that newest version.
    private var modelChoices: [ModelChoice] {
        let families = catalog.models.isEmpty
            ? ClaudeModelCatalog.aliasFamilies.map { ($0, $0.capitalized, nil as ClaudeModelInfo?) }
            : catalog.models.map { ($0.family, $0.shortName, $0 as ClaudeModelInfo?) }
        return families.map { family, name, info in
            let style = Self.familyStyle[family] ?? ("Claude model", "sparkle")
            var hint = style.hint
            if let tokens = info?.maxInputTokens { hint += " · \(Self.contextLabel(tokens)) context" }
            let command = ClaudeModelCatalog.aliasFamilies.contains(family) ? family : (info?.id ?? family)
            let isActive = activeModelID != nil && (activeModelID == info?.id || activeModelID?.contains("-\(family)-") == true)
            return ModelChoice(name: name, command: command, hint: hint, symbol: style.symbol, isActive: isActive)
        }
    }

    /// The API has no descriptions, so each family keeps a short one here.
    private static let familyStyle: [String: (hint: String, symbol: String)] = [
        "fable": ("Strongest · densest reasoning · 2.5× Opus price", "crown.fill"),
        "opus": ("Most capable everyday model · Fast mode", "bolt.fill"),
        "sonnet": ("Balanced speed and capability", "scalemass.fill"),
        "haiku": ("Fastest · cheapest", "hare.fill"),
    ]

    private static func contextLabel(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M" : "\(tokens / 1000)K"
    }
}
