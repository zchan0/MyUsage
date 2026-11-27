import AppKit
import SwiftUI

/// Compact inline statusline strip embedded directly inside Claude Code and
/// Antigravity provider rows in Settings → Providers, keeping each provider's
/// visibility, ordering, and CLI hook controls unified in one place.
struct StatuslineInlineStrip: View {
    let label: String
    let bridgeState: StatuslineBridgeState
    let dataState: StatuslineDataState
    let lastReceivedAt: Date?
    let issue: String?
    let waitingHint: String
    let notConnectedHint: String
    let infoHelp: String
    let settingsURL: URL
    let onConnect: () throws -> String
    let onDisconnect: () throws -> String
    let onReconnect: () throws -> String
    let onReset: () throws -> String
    let onRefresh: @MainActor () async -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var notice: ActionNotice?

    private struct ActionNotice: Equatable {
        let text: String
        let isError: Bool
    }

    private var palette: PopoverPalette { PopoverPalette(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6.5, height: 6.5)

                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(statusSummary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(statusTooltip)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(infoHelp)
                }

                Spacer(minLength: 8)

                actionControls
                    .fixedSize()
            }

            if let detail = inlineDetail {
                Text(detail.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(detail.isError ? palette.critInk : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14.5)
                    .transition(.opacity.combined(with: .offset(y: -2)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(stripBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(stripBorder, lineWidth: 0.5)
                }
        }
        .animation(PopoverMotion.disclosure, value: inlineDetail?.text)
        .onAppear {
            notice = nil
            Task { await onRefresh() }
        }
        .onChange(of: dataState) { _, newState in
            if newState == .valid, notice?.isError == false { notice = nil }
        }
    }

    private var stripBackground: Color {
        if bridgeState == .modifiedExternally || dataState == .invalid {
            return palette.critPillBackground
        }
        if bridgeState == .appMoved {
            return palette.warnPillBackground
        }
        return colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.032)
    }

    private var stripBorder: Color {
        if bridgeState == .modifiedExternally || dataState == .invalid {
            return palette.critFill.opacity(0.28)
        }
        if bridgeState == .appMoved {
            return palette.warnFill.opacity(0.28)
        }
        return (colorScheme == .dark ? Color.white : Color.black).opacity(0.06)
    }

    @ViewBuilder
    private var actionControls: some View {
        switch bridgeState {
        case .notInstalled:
            Button("Connect") { perform(onConnect) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        case .installed:
            Button("Disconnect") { perform(onDisconnect) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        case .appMoved:
            HStack(spacing: 6) {
                Button("Reconnect") { perform(onReconnect) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                Button("Disconnect") { perform(onDisconnect) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        case .modifiedExternally:
            HStack(spacing: 6) {
                if FileManager.default.fileExists(atPath: settingsURL.path) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([settingsURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Show settings.json in Finder")
                }
                Button("Reset") { perform(onReset) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Clear MyUsage's installation record without editing settings.json")
            }
        }
    }

    private func perform(_ work: () throws -> String) {
        do {
            let success = try work()
            notice = ActionNotice(text: success, isError: false)
        } catch {
            notice = ActionNotice(text: error.localizedDescription, isError: true)
        }
        Task { await onRefresh() }
    }

    private var statusColor: Color {
        switch bridgeState {
        case .notInstalled:
            return dataState == .invalid ? palette.critFill : .secondary.opacity(0.55)
        case .modifiedExternally:
            return palette.critFill
        case .appMoved:
            return palette.warnFill
        case .installed:
            switch dataState {
            case .valid: return palette.okFill
            case .waiting, .stale: return palette.warnFill
            case .invalid: return palette.critFill
            case .notConnected: return .secondary.opacity(0.55)
            }
        }
    }

    private var statusSummary: String {
        let timestamp = lastReceivedAt.map { " · \($0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened))" } ?? ""
        switch bridgeState {
        case .notInstalled:
            return "Not connected\(timestamp)"
        case .modifiedExternally:
            return "Edited externally\(timestamp)"
        case .appMoved:
            return "App moved — reconnect needed\(timestamp)"
        case .installed:
            switch dataState {
            case .valid: return "Connected\(timestamp)"
            case .waiting: return "Connected · Waiting for quota"
            case .stale: return "Connected · Old snapshot\(timestamp)"
            case .invalid: return "Connected · Snapshot unavailable"
            case .notConnected: return "Not connected\(timestamp)"
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
            return (notice.text, notice.isError)
        }
        switch bridgeState {
        case .modifiedExternally:
            return ("Your settings.json was preserved. Review it or click Reset to reconnect cleanly.", true)
        case .appMoved:
            return ("Statusline points to an older MyUsage path. Click Reconnect to update it.", false)
        case .installed:
            if dataState == .invalid, let issue { return (issue, true) }
            if dataState == .waiting { return (waitingHint, false) }
            return nil
        case .notInstalled:
            if dataState == .invalid, let issue { return (issue, true) }
            return (notConnectedHint, false)
        }
    }
}

/// Convenience builders binding `ClaudeProvider` and `AntigravityProvider` to
/// `StatuslineInlineStrip`.
enum StatuslineStripFactory {
    @MainActor
    static func claude(_ provider: ClaudeProvider) -> StatuslineInlineStrip {
        StatuslineInlineStrip(
            label: "Statusline",
            bridgeState: provider.bridgeState,
            dataState: provider.dataState,
            lastReceivedAt: provider.receipt.map { Date(timeIntervalSince1970: $0.receivedAt) },
            issue: provider.statuslineIssue,
            waitingHint: "Send a message in Claude Code to receive the first snapshot.",
            notConnectedHint: "Opt-in quota source via ~/.claude/settings.json.",
            infoHelp: "\(provider.sourceMessage)\n\nConfig: \(provider.bridge.settingsURL.path)\nPreserves your existing statusLine command, stdout/stderr, and other settings. Moving MyUsage requires reconnecting.",
            settingsURL: provider.bridge.settingsURL,
            onConnect: {
                try provider.bridge.enable()
                return "Connected. Use Claude Code normally to receive quota."
            },
            onDisconnect: {
                try provider.bridge.disable()
                return "Disconnected. Existing local snapshots were kept."
            },
            onReconnect: {
                try provider.bridge.reconnect()
                return "Updated statusline path to this MyUsage app."
            },
            onReset: {
                try provider.bridge.resetInstallationRecord()
                return "Cleared MyUsage's record without editing settings.json."
            },
            onRefresh: { await provider.refresh(trigger: .manual) }
        )
    }

    @MainActor
    static func antigravity(_ provider: AntigravityProvider) -> StatuslineInlineStrip {
        StatuslineInlineStrip(
            label: "CLI Statusline",
            bridgeState: provider.statuslineBridgeState,
            dataState: provider.statuslineDataState,
            lastReceivedAt: provider.statuslineReceipt.map { Date(timeIntervalSince1970: $0.receivedAt) },
            issue: provider.statuslineIssue,
            waitingHint: "Open a new agy session and run a turn to receive quota.",
            notConnectedHint: "Optional fallback via ~/.gemini/antigravity-cli/settings.json.",
            infoHelp: "\(provider.statuslineSourceMessage)\n\nConfig: \(provider.bridge.settingsURL.path)\nFallback when local process quota is unavailable (e.g. Antigravity 2.34+ or CLI-only sessions). Preserves existing commands and settings; restart open agy sessions to apply.",
            settingsURL: provider.bridge.settingsURL,
            onConnect: {
                try provider.bridge.enable()
                return "Connected. New agy sessions will report quota here."
            },
            onDisconnect: {
                try provider.bridge.disable()
                return "Disconnected. Existing local snapshots were kept."
            },
            onReconnect: {
                try provider.bridge.reconnect()
                return "Updated statusline path to this MyUsage app."
            },
            onReset: {
                try provider.bridge.resetInstallationRecord()
                return "Cleared MyUsage's record without editing settings.json."
            },
            onRefresh: { await provider.refresh(trigger: .manual) }
        )
    }
}

#if DEBUG
#Preview("Inline statusline states") {
    let now = Date.now
    VStack(spacing: 10) {
        StatuslineInlineStrip(
            label: "Statusline",
            bridgeState: .installed,
            dataState: .valid,
            lastReceivedAt: now.addingTimeInterval(-120),
            issue: nil,
            waitingHint: "",
            notConnectedHint: "",
            infoHelp: "Details",
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
            onConnect: { "" }, onDisconnect: { "" }, onReconnect: { "" }, onReset: { "" },
            onRefresh: {}
        )
        StatuslineInlineStrip(
            label: "CLI Statusline",
            bridgeState: .installed,
            dataState: .waiting,
            lastReceivedAt: nil,
            issue: nil,
            waitingHint: "Open a new agy session and run a turn to receive quota.",
            notConnectedHint: "",
            infoHelp: "Details",
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
            onConnect: { "" }, onDisconnect: { "" }, onReconnect: { "" }, onReset: { "" },
            onRefresh: {}
        )
        StatuslineInlineStrip(
            label: "Statusline",
            bridgeState: .appMoved,
            dataState: .valid,
            lastReceivedAt: now.addingTimeInterval(-600),
            issue: nil,
            waitingHint: "",
            notConnectedHint: "",
            infoHelp: "Details",
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
            onConnect: { "" }, onDisconnect: { "" }, onReconnect: { "" }, onReset: { "" },
            onRefresh: {}
        )
        StatuslineInlineStrip(
            label: "Statusline",
            bridgeState: .modifiedExternally,
            dataState: .invalid,
            lastReceivedAt: now.addingTimeInterval(-3600),
            issue: "The configured statusline no longer matches MyUsage.",
            waitingHint: "",
            notConnectedHint: "",
            infoHelp: "Details",
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
            onConnect: { "" }, onDisconnect: { "" }, onReconnect: { "" }, onReset: { "" },
            onRefresh: {}
        )
        StatuslineInlineStrip(
            label: "CLI Statusline",
            bridgeState: .notInstalled,
            dataState: .notConnected,
            lastReceivedAt: nil,
            issue: nil,
            waitingHint: "",
            notConnectedHint: "Optional fallback via ~/.gemini/antigravity-cli/settings.json.",
            infoHelp: "Details",
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
            onConnect: { "" }, onDisconnect: { "" }, onReconnect: { "" }, onReset: { "" },
            onRefresh: {}
        )
    }
    .padding(16)
    .frame(width: 460)
}
#endif
