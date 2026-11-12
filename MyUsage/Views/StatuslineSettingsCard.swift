import AppKit
import SwiftUI

/// Compact, state-aware statusline integration card for Settings → Providers.
/// Replaces verbose text blocks and always-active enable/disable button pairs
/// with a live status indicator and a single contextual action per CLI.
struct StatuslineIntegrationsCard: View {
    let claude: ClaudeProvider?
    let antigravity: AntigravityProvider?

    @State private var claudeNotice: ActionNotice?
    @State private var antigravityNotice: ActionNotice?

    private struct ActionNotice: Equatable {
        let text: String
        let isError: Bool
    }

    var body: some View {
        if claude != nil || antigravity != nil {
            VStack(alignment: .leading, spacing: 6) {
                SettingsCard("Statusline Integrations") {
                    VStack(alignment: .leading, spacing: 0) {
                        if let claude {
                            StatuslineIntegrationRow(
                                source: .builtin(.claude),
                                title: "Claude Code",
                                bridgeState: claude.bridgeState,
                                dataState: claude.dataState,
                                lastReceivedAt: claude.receipt.map { Date(timeIntervalSince1970: $0.receivedAt) },
                                issue: claude.statuslineIssue,
                                notice: claudeNotice.map { ($0.text, $0.isError) },
                                waitingHint: "Send a message in Claude Code to receive the first snapshot.",
                                notConnectedHint: "Opt-in quota source via ~/.claude/settings.json.",
                                infoHelp: claudeInfoHelp(claude),
                                settingsURL: claude.bridge.settingsURL,
                                onConnect: {
                                    performAction(for: &claudeNotice) {
                                        try claude.bridge.enable()
                                        return "Connected. Use Claude Code normally to receive quota."
                                    } refresh: {
                                        await claude.refresh(trigger: .manual)
                                    }
                                },
                                onDisconnect: {
                                    performAction(for: &claudeNotice) {
                                        try claude.bridge.disable()
                                        return "Disconnected. Existing local snapshots were kept."
                                    } refresh: {
                                        await claude.refresh(trigger: .manual)
                                    }
                                },
                                onReconnect: {
                                    performAction(for: &claudeNotice) {
                                        try claude.bridge.reconnect()
                                        return "Updated statusline path to this MyUsage app."
                                    } refresh: {
                                        await claude.refresh(trigger: .manual)
                                    }
                                },
                                onReset: {
                                    performAction(for: &claudeNotice) {
                                        try claude.bridge.resetInstallationRecord()
                                        return "Cleared MyUsage's record without editing settings.json."
                                    } refresh: {
                                        await claude.refresh(trigger: .manual)
                                    }
                                }
                            )
                        }

                        if claude != nil && antigravity != nil {
                            CardDivider()
                        }

                        if let antigravity {
                            StatuslineIntegrationRow(
                                source: .builtin(.antigravity),
                                title: "Antigravity CLI",
                                bridgeState: antigravity.statuslineBridgeState,
                                dataState: antigravity.statuslineDataState,
                                lastReceivedAt: antigravity.statuslineReceipt.map { Date(timeIntervalSince1970: $0.receivedAt) },
                                issue: antigravity.statuslineIssue,
                                notice: antigravityNotice.map { ($0.text, $0.isError) },
                                waitingHint: "Open a new agy session and run a turn to receive quota.",
                                notConnectedHint: "Optional fallback via ~/.gemini/antigravity-cli/settings.json.",
                                infoHelp: antigravityInfoHelp(antigravity),
                                settingsURL: antigravity.bridge.settingsURL,
                                onConnect: {
                                    performAction(for: &antigravityNotice) {
                                        try antigravity.bridge.enable()
                                        return "Connected. New agy sessions will report quota here."
                                    } refresh: {
                                        await antigravity.refresh(trigger: .manual)
                                    }
                                },
                                onDisconnect: {
                                    performAction(for: &antigravityNotice) {
                                        try antigravity.bridge.disable()
                                        return "Disconnected. Existing local snapshots were kept."
                                    } refresh: {
                                        await antigravity.refresh(trigger: .manual)
                                    }
                                },
                                onReconnect: {
                                    performAction(for: &antigravityNotice) {
                                        try antigravity.bridge.reconnect()
                                        return "Updated statusline path to this MyUsage app."
                                    } refresh: {
                                        await antigravity.refresh(trigger: .manual)
                                    }
                                },
                                onReset: {
                                    performAction(for: &antigravityNotice) {
                                        try antigravity.bridge.resetInstallationRecord()
                                        return "Cleared MyUsage's record without editing settings.json."
                                    } refresh: {
                                        await antigravity.refresh(trigger: .manual)
                                    }
                                }
                            )
                        }
                    }
                }

                Text("Wraps each CLI's statusLine command without modifying other settings. Snapshots stay local and are never synced.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .onAppear {
                claudeNotice = nil
                antigravityNotice = nil
                Task {
                    await claude?.refresh(trigger: .manual)
                    await antigravity?.refresh(trigger: .manual)
                }
            }
            .onChange(of: claude?.dataState) { _, newState in
                if newState == .valid, claudeNotice?.isError == false { claudeNotice = nil }
            }
            .onChange(of: antigravity?.statuslineDataState) { _, newState in
                if newState == .valid, antigravityNotice?.isError == false { antigravityNotice = nil }
            }
        }
    }

    private func performAction(
        for notice: inout ActionNotice?,
        work: () throws -> String,
        refresh: @escaping @MainActor () async -> Void
    ) {
        do {
            let success = try work()
            notice = ActionNotice(text: success, isError: false)
        } catch {
            notice = ActionNotice(text: error.localizedDescription, isError: true)
        }
        Task { await refresh() }
    }

    private func claudeInfoHelp(_ claude: ClaudeProvider) -> String {
        "\(claude.sourceMessage)\n\nConfig: \(claude.bridge.settingsURL.path)\nPreserves your existing statusLine command, stdout/stderr, and other settings. Moving MyUsage requires reconnecting."
    }

    private func antigravityInfoHelp(_ antigravity: AntigravityProvider) -> String {
        "\(antigravity.statuslineSourceMessage)\n\nConfig: \(antigravity.bridge.settingsURL.path)\nFallback when local process quota is unavailable (e.g. Antigravity 2.34+ or CLI-only sessions). Preserves existing commands and settings; restart open agy sessions to apply."
    }
}

struct StatuslineIntegrationRow: View {
    let source: ProviderSource
    let title: String
    let bridgeState: StatuslineBridgeState
    let dataState: StatuslineDataState
    let lastReceivedAt: Date?
    let issue: String?
    let notice: (text: String, isError: Bool)?
    let waitingHint: String
    let notConnectedHint: String
    let infoHelp: String
    let settingsURL: URL
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onReset: () -> Void

    private static let okColor = Color(hue: 145.0 / 360.0, saturation: 0.45, brightness: 0.55)
    private static let warnColor = Color(hue: 38.0 / 360.0, saturation: 0.92, brightness: 0.62)
    private static let errorColor = Color(hue: 8.0 / 360.0, saturation: 0.78, brightness: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                ProviderInstanceIcon(source: source, size: 24, glyph: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .help(infoHelp)
                    }

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusSummary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(statusTooltip)
                    }
                }

                Spacer(minLength: 8)

                actionControls
            }

            if let detail = inlineDetail {
                Text(detail.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(detail.isError ? Self.errorColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionControls: some View {
        switch bridgeState {
        case .notInstalled:
            Button("Connect", action: onConnect)
                .controlSize(.small)
        case .installed:
            Button("Disconnect", action: onDisconnect)
                .controlSize(.small)
        case .appMoved:
            HStack(spacing: 6) {
                Button("Reconnect", action: onReconnect)
                    .controlSize(.small)
                Button("Disconnect", action: onDisconnect)
                    .controlSize(.small)
            }
        case .modifiedExternally:
            HStack(spacing: 6) {
                if FileManager.default.fileExists(atPath: settingsURL.path) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([settingsURL])
                    }
                    .controlSize(.small)
                    .help("Show settings.json in Finder")
                }
                Button("Reset", action: onReset)
                    .controlSize(.small)
                    .help("Clear MyUsage's installation record without editing settings.json")
            }
        }
    }

    private var statusColor: Color {
        switch bridgeState {
        case .notInstalled:
            return dataState == .invalid ? Self.errorColor : .secondary.opacity(0.6)
        case .modifiedExternally:
            return Self.errorColor
        case .appMoved:
            return Self.warnColor
        case .installed:
            switch dataState {
            case .valid: return Self.okColor
            case .waiting, .stale: return Self.warnColor
            case .invalid: return Self.errorColor
            case .notConnected: return .secondary.opacity(0.6)
            }
        }
    }

    private var statusSummary: String {
        let timestamp = lastReceivedAt.map { " · Last \(Self.compactTime($0))" } ?? ""
        switch bridgeState {
        case .notInstalled:
            return "Not connected\(timestamp)"
        case .modifiedExternally:
            return "Config changed outside MyUsage\(timestamp)"
        case .appMoved:
            return "App moved — reconnect needed\(timestamp)"
        case .installed:
            switch dataState {
            case .valid:
                return "Connected\(timestamp)"
            case .waiting:
                return "Connected · Waiting for first quota"
            case .stale:
                return "Connected · Old snapshot\(timestamp)"
            case .invalid:
                return "Connected · Snapshot unavailable"
            case .notConnected:
                return "Not connected\(timestamp)"
            }
        }
    }

    private var statusTooltip: String {
        if let lastReceivedAt {
            return "Last snapshot received locally on \(lastReceivedAt.formatted(date: .abbreviated, time: .standard)). Server sample time is not provided."
        }
        return statusSummary
    }

    private var inlineDetail: (text: String, isError: Bool)? {
        if let notice {
            return notice
        }
        switch bridgeState {
        case .modifiedExternally:
            return ("Your settings.json was preserved. Review it or click Reset to reconnect cleanly.", true)
        case .appMoved:
            return ("Statusline still points to an older MyUsage path. Click Reconnect to update it.", false)
        case .installed:
            if dataState == .invalid, let issue {
                return (issue, true)
            }
            if dataState == .waiting {
                return (waitingHint, false)
            }
            return nil
        case .notInstalled:
            if dataState == .invalid, let issue {
                return (issue, true)
            }
            return (notConnectedHint, false)
        }
    }

    private static func compactTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#if DEBUG
#Preview("Statusline integration states") {
    let now = Date.now
    SettingsCard("Statusline Integrations") {
        VStack(alignment: .leading, spacing: 0) {
            StatuslineIntegrationRow(
                source: .builtin(.claude),
                title: "Claude Code",
                bridgeState: .installed,
                dataState: .valid,
                lastReceivedAt: now.addingTimeInterval(-120),
                issue: nil,
                notice: nil,
                waitingHint: "Send a message in Claude Code to receive the first snapshot.",
                notConnectedHint: "Opt-in quota source via ~/.claude/settings.json.",
                infoHelp: "Details",
                settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
                onConnect: {},
                onDisconnect: {},
                onReconnect: {},
                onReset: {}
            )
            CardDivider()
            StatuslineIntegrationRow(
                source: .builtin(.antigravity),
                title: "Antigravity CLI",
                bridgeState: .installed,
                dataState: .waiting,
                lastReceivedAt: nil,
                issue: nil,
                notice: nil,
                waitingHint: "Open a new agy session and run a turn to receive quota.",
                notConnectedHint: "Optional fallback via ~/.gemini/antigravity-cli/settings.json.",
                infoHelp: "Details",
                settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
                onConnect: {},
                onDisconnect: {},
                onReconnect: {},
                onReset: {}
            )
            CardDivider()
            StatuslineIntegrationRow(
                source: .builtin(.claude),
                title: "Claude Code (Moved)",
                bridgeState: .appMoved,
                dataState: .valid,
                lastReceivedAt: now.addingTimeInterval(-600),
                issue: nil,
                notice: nil,
                waitingHint: "",
                notConnectedHint: "",
                infoHelp: "Details",
                settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
                onConnect: {},
                onDisconnect: {},
                onReconnect: {},
                onReset: {}
            )
            CardDivider()
            StatuslineIntegrationRow(
                source: .builtin(.claude),
                title: "Claude Code (Edited)",
                bridgeState: .modifiedExternally,
                dataState: .invalid,
                lastReceivedAt: now.addingTimeInterval(-3600),
                issue: "The configured statusline no longer matches MyUsage.",
                notice: nil,
                waitingHint: "",
                notConnectedHint: "",
                infoHelp: "Details",
                settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
                onConnect: {},
                onDisconnect: {},
                onReconnect: {},
                onReset: {}
            )
            CardDivider()
            StatuslineIntegrationRow(
                source: .builtin(.antigravity),
                title: "Antigravity CLI (Off)",
                bridgeState: .notInstalled,
                dataState: .notConnected,
                lastReceivedAt: nil,
                issue: nil,
                notice: nil,
                waitingHint: "",
                notConnectedHint: "Optional fallback via ~/.gemini/antigravity-cli/settings.json.",
                infoHelp: "Details",
                settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
                onConnect: {},
                onDisconnect: {},
                onReconnect: {},
                onReset: {}
            )
        }
    }
    .padding(16)
    .frame(width: 520)
}
#endif
