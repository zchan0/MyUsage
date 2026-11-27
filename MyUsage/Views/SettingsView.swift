import AppKit
import SwiftUI
import ServiceManagement

/// macOS 26 Settings window with a 4-section floating Liquid Glass sidebar:
/// General, Providers, Notifications, and About.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case providers = "Providers"
        case notifications = "Notifications"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .providers: "square.stack.3d.up.fill"
            case .notifications: "bell.badge.fill"
            case .about: "info.circle.fill"
            }
        }

        var badgeTint: Color {
            switch self {
            case .general: Color(red: 0.28, green: 0.54, blue: 0.94)
            case .providers: Color(red: 0.20, green: 0.66, blue: 0.56)
            case .notifications: Color(red: 0.90, green: 0.53, blue: 0.20)
            case .about: Color(red: 0.48, green: 0.52, blue: 0.60)
            }
        }
    }

    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(\.colorScheme) private var colorScheme

    @Namespace private var sidebarNamespace
    @State private var selection: Section = .general
    @State private var hoveredSection: Section?
    @State private var installer = UpdateInstaller.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var crashLogStatus: String?
    @State private var gatewayEditor: GatewayEditorTarget?

    init(initialSection: Section = .general) {
        _selection = State(initialValue: initialSection)
    }

    private var palette: PopoverPalette { PopoverPalette(colorScheme) }

    private var windowCanvas: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.12, blue: 0.145)
            : Color(red: 0.953, green: 0.957, blue: 0.968)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
                .padding(.leading, 12)
                .padding(.vertical, 12)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(windowCanvas)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(width: 700, height: 520)
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            let all = Section.allCases
            guard let index = all.firstIndex(of: selection) else { return .ignored }
            let offset = press.key == .upArrow ? -1 : 1
            withAnimation(PopoverMotion.selection) {
                selection = all[(index + offset + all.count) % all.count]
            }
            return .handled
        }
        .sheet(item: $gatewayEditor) { target in
            GatewayConnectionEditor(connection: target.connection)
        }
    }

    // MARK: - Floating Liquid Glass Sidebar

    private var sidebar: some View {
        let isDark = colorScheme == .dark
        let sidebarShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            GlassEffectContainer(spacing: 4) {
                VStack(spacing: 3) {
                    ForEach(Section.allCases) { section in
                        sidebarRow(section)
                    }
                }
            }
            .padding(8)

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text("MyUsage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)
                Spacer(minLength: 4)
                Text("v\(AppInfo.version)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.inkTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
        }
        .frame(maxHeight: .infinity)
        .background {
            sidebarShape
                .fill(
                    LinearGradient(
                        colors: isDark
                            ? [Color.white.opacity(0.068), Color.white.opacity(0.042)]
                            : [Color.white.opacity(0.76), Color.white.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(isDark ? 0.24 : 0.05), radius: isDark ? 8 : 5, y: 2)
        }
        .overlay {
            sidebarShape
                .strokeBorder(
                    (isDark ? Color.white : Color.black).opacity(isDark ? 0.11 : 0.07),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
        .glassEffect(.clear, in: sidebarShape)
    }

    private func sidebarRow(_ section: Section) -> some View {
        let selected = selection == section
        let hovered = hoveredSection == section
        let rowShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let isDark = colorScheme == .dark

        return Button {
            withAnimation(PopoverMotion.selection) {
                selection = section
            }
        } label: {
            HStack(spacing: 9) {
                SettingsSidebarBadge(symbol: section.symbol, tint: section.badgeTint)
                Text(section.rawValue)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected || hovered ? palette.inkPrimary : palette.inkSecondary)
                Spacer(minLength: 4)
                sidebarAccessory(for: section)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    rowShape
                        .fill(
                            isDark
                                ? Color.white.opacity(0.13)
                                : Color.white.opacity(0.95)
                        )
                        .overlay {
                            rowShape.strokeBorder(
                                (isDark ? Color.white : Color.black).opacity(isDark ? 0.14 : 0.08),
                                lineWidth: 0.5
                            )
                        }
                        .shadow(color: .black.opacity(isDark ? 0.24 : 0.06), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "sidebarSelection", in: sidebarNamespace)
                } else if hovered {
                    rowShape.fill(palette.rowHover)
                }
            }
            .glassEffect(selected ? .clear.interactive() : .identity, in: rowShape)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(PopoverMotion.hover) {
                if inside { hoveredSection = section }
                else if hoveredSection == section { hoveredSection = nil }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func sidebarAccessory(for section: Section) -> some View {
        switch section {
        case .providers where hasProviderAttention:
            Circle()
                .fill(palette.warnFill)
                .frame(width: 7, height: 7)
                .help("A statusline integration needs attention")
        case .about where updateChecker.updateAvailable != nil:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .help("Update available")
        default:
            EmptyView()
        }
    }

    private var hasProviderAttention: Bool {
        if let claude = manager.providers.first(where: { $0 is ClaudeProvider }) as? ClaudeProvider,
           claude.bridgeState == .appMoved || claude.bridgeState == .modifiedExternally {
            return true
        }
        if let antigravity = manager.providers.first(where: { $0 is AntigravityProvider }) as? AntigravityProvider,
           antigravity.statuslineBridgeState == .appMoved || antigravity.statuslineBridgeState == .modifiedExternally {
            return true
        }
        return false
    }

    // MARK: - Detail Router

    private var detailPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("detailTop")

                    VStack(alignment: .leading, spacing: 16) {
                        switch selection {
                        case .general:
                            generalPane
                        case .providers:
                            providersPane
                        case .notifications:
                            notificationsPane
                        case .about:
                            aboutPane
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectHidden(true, for: .all)
            .onChange(of: selection) { _, _ in
                proxy.scrollTo("detailTop", anchor: .top)
            }
        }
    }

    // MARK: - General

    private var generalPane: some View {
        @Bindable var mgr = manager
        return Group {
            SettingsPageHeader(
                "General",
                subtitle: "Configure menu bar layout, polling cadence, and login behavior."
            )

            SettingsCard("Menu Bar") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Icon Layout")
                            .font(.system(size: 12.5, weight: .medium))

                        HStack(spacing: 10) {
                            menuBarModeTile(
                                mode: .merged,
                                title: "Merged",
                                detail: "Single icon + dock",
                                symbol: "menubar.dock.rectangle"
                            )
                            menuBarModeTile(
                                mode: .separate,
                                title: "One per provider",
                                detail: "One icon per tool",
                                symbol: "square.grid.2x2"
                            )
                        }
                    }
                    .padding(.vertical, 9)

                    if manager.menuBarMode == .merged {
                        CardDivider()

                        SettingsRow(
                            "Tracked provider",
                            caption: "Supplies the icon and live percentage shown in the menu bar."
                        ) {
                            Picker("", selection: $mgr.iconTrackProvider) {
                                Text("None").tag("")
                                ForEach(manager.orderedProviders, id: \.id) { provider in
                                    Text(provider.displayName).tag(provider.id.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 165)
                        }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .animation(PopoverMotion.disclosure, value: manager.menuBarMode)
            }

            SettingsCard("Refresh") {
                SettingsRow(
                    "Polling interval",
                    caption: "How often active providers refresh. Local statusline sources never make network requests."
                ) {
                    Picker("", selection: $mgr.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 145)
                }
            }

            SettingsCard("System") {
                SettingsRow(
                    "Launch at Login",
                    caption: "Start MyUsage automatically in the menu bar when you sign in."
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }
        }
    }

    private func menuBarModeTile(
        mode: UsageManager.MenuBarMode,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        let selected = manager.menuBarMode == mode
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button {
            withAnimation(PopoverMotion.selection) {
                manager.menuBarMode = mode
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        (selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(selected ? Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09) : Color.primary.opacity(0.03))
            }
            .overlay {
                shape.strokeBorder(
                    selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: selected ? 1.2 : 0.5
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Providers

    private var providersPane: some View {
        let ordered = manager.orderedProviders
        let hasGateways = ordered.contains { $0 is GatewayProvider }
        return Group {
            SettingsPageHeader(
                "Providers",
                subtitle: "Toggle visibility, set dock order, and configure integrations."
            )

            if let error = manager.gatewaySettingsError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.warnFill)
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.warnPillBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            SettingsCard("Active Providers") {
                Text("\(ordered.filter(\.isEnabled).count) of \(ordered.count) enabled")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, provider in
                        providerRow(provider, at: index, total: ordered.count)
                        if index < ordered.count - 1 {
                            CardDivider()
                        }
                    }
                }
            }

            SettingsCard("Custom Gateways") {
                SettingsRow(
                    hasGateways ? "Add another LiteLLM gateway" : "Connect a LiteLLM gateway",
                    caption: "Track team or personal API spend and model usage alongside local coding tools."
                ) {
                    Button("Add Gateway…") {
                        gatewayEditor = .init(connection: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Statusline integrations wrap each CLI's statusLine command without altering other settings. Snapshots stay local on this Mac.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    private func providerRow(_ provider: any UsageProvider, at index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ProviderInstanceIcon(source: provider.source, size: 26, glyph: 15)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .help(provider.displayName)

                        if provider is GatewayProvider {
                            Text("Gateway")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                    detectionLabel(provider)
                }

                Spacer(minLength: 10)

                if let gateway = provider as? GatewayProvider {
                    Button {
                        gatewayEditor = .init(connection: gateway.connection)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Edit \(provider.displayName)")
                }

                reorderButtons(at: index, total: total)

                Toggle("", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { newValue in
                        manager.setEnabled(newValue, for: provider)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            if let claude = provider as? ClaudeProvider {
                StatuslineStripFactory.claude(claude)
                    .padding(.leading, 38)
            } else if let antigravity = provider as? AntigravityProvider {
                StatuslineStripFactory.antigravity(antigravity)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 9)
    }

    private func reorderButtons(at index: Int, total: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(PopoverMotion.selection) {
                    manager.moveProvider(from: IndexSet([index]), to: index - 1)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(index == 0 ? 0.28 : 1)
            .disabled(index == 0)
            .help("Move up")

            Button {
                withAnimation(PopoverMotion.selection) {
                    manager.moveProvider(from: IndexSet([index]), to: index + 2)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(index == total - 1 ? 0.28 : 1)
            .disabled(index == total - 1)
            .help("Move down")
        }
    }

    @ViewBuilder
    private func detectionLabel(_ provider: any UsageProvider) -> some View {
        if let gateway = provider as? GatewayProvider {
            Text("\(gateway.connection.vendor.displayName) · \(gateway.connection.baseURL.host ?? "")")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let claude = provider as? ClaudeProvider {
            Text(claude.stateLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else if let antigravity = provider as? AntigravityProvider, antigravity.quotaSource == .statusline {
            Text(antigravity.statuslineStateLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else if provider.isAvailable {
            HStack(spacing: 5) {
                Circle()
                    .fill(palette.okFill)
                    .frame(width: 5.5, height: 5.5)
                Text("Detected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Not found")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Notifications

    private var notificationsPane: some View {
        @Bindable var mgr = manager
        return Group {
            SettingsPageHeader(
                "Notifications",
                subtitle: "Send a macOS alert when any tracked window crosses your warning or critical threshold."
            )

            SettingsCard("Limit Pressure Alerts") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(
                        "Notify when limits get tight",
                        caption: "Delivers one alert per threshold crossing until that window resets."
                    ) {
                        Toggle("", isOn: $mgr.notificationsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    CardDivider()

                    thresholdPreviewBar
                        .padding(.vertical, 12)
                        .opacity(manager.notificationsEnabled ? 1 : 0.45)

                    CardDivider()

                    thresholdRow(
                        title: "Warn at",
                        caption: "First-tier alert. Bars visually turn amber at 75%.",
                        value: $mgr.notifyWarnThreshold,
                        range: 50...90,
                        tint: palette.warnFill,
                        ceiling: { mgr.notifyCritThreshold - 1 }
                    )
                    .disabled(!manager.notificationsEnabled)
                    .opacity(manager.notificationsEnabled ? 1 : 0.5)

                    CardDivider()

                    thresholdRow(
                        title: "Critical at",
                        caption: "Urgent ⚠︎ alert. Bars visually turn red at 90%.",
                        value: $mgr.notifyCritThreshold,
                        range: 80...99,
                        tint: palette.critFill,
                        floor: { mgr.notifyWarnThreshold + 1 }
                    )
                    .disabled(!manager.notificationsEnabled)
                    .opacity(manager.notificationsEnabled ? 1 : 0.5)
                }
            }

            Text("Only active, valid snapshots generate notifications. Stale, waiting, or disconnected statusline receipts are excluded.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    private var thresholdPreviewBar: some View {
        let warn = manager.notifyWarnThreshold / 100
        let crit = manager.notifyCritThreshold / 100
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Alert zones")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    zoneLegend(color: palette.warnFill, text: "Warn \(Int(manager.notifyWarnThreshold))%")
                    zoneLegend(color: palette.critFill, text: "Critical \(Int(manager.notifyCritThreshold))%")
                }
                .contentTransition(.numericText())
                .animation(PopoverMotion.numeric, value: manager.notifyWarnThreshold)
                .animation(PopoverMotion.numeric, value: manager.notifyCritThreshold)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let warnW = max(0, w * warn)
                let critW = max(0, w * max(0, crit - warn))
                let tailW = max(0, w - warnW - critW)

                HStack(spacing: 1.5) {
                    Rectangle().fill(palette.okFill.opacity(0.78)).frame(width: warnW)
                    Rectangle().fill(palette.warnFill.opacity(0.9)).frame(width: critW)
                    Rectangle().fill(palette.critFill.opacity(0.92)).frame(width: tailW)
                }
                .clipShape(Capsule())
                .animation(PopoverMotion.meter, value: warn)
                .animation(PopoverMotion.meter, value: crit)
            }
            .frame(height: 7)
        }
    }

    private func zoneLegend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func thresholdRow(
        title: String,
        caption: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        tint: Color,
        floor: (() -> Double)? = nil,
        ceiling: (() -> Double)? = nil
    ) -> some View {
        let clampedBinding = Binding<Double>(
            get: { value.wrappedValue },
            set: { newValue in
                var v = max(range.lowerBound, min(range.upperBound, newValue.rounded()))
                if let f = floor?() { v = max(v, f) }
                if let c = ceiling?() { v = min(v, c) }
                value.wrappedValue = v
            }
        )

        return SettingsRow(title, caption: caption) {
            HStack(spacing: 8) {
                Slider(value: clampedBinding, in: range)
                    .tint(tint)
                    .frame(width: 112)

                Text("\(Int(value.wrappedValue))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(PopoverMotion.numeric, value: value.wrappedValue)
                    .frame(width: 36, alignment: .trailing)

                Stepper("", value: clampedBinding, in: range, step: 1)
                    .labelsHidden()
            }
        }
    }

    // MARK: - About

    private var aboutPane: some View {
        Group {
            SettingsPageHeader(
                "About",
                subtitle: "Version details, updates, and local diagnostics."
            )

            if let release = updateChecker.updateAvailable {
                updateBanner(release)
            }

            SettingsCard {
                HStack(spacing: 16) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                    } else {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.tint)
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("MyUsage")
                                .font(.system(size: 17, weight: .bold))
                            Text("v\(AppInfo.versionWithBuild)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }

                        Text("Monitor AI coding tool limits, local usage, and gateways from your menu bar.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Link(destination: URL(string: "https://github.com/zchan0/MyUsage")!) {
                                Label("GitHub", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }

            SettingsCard("Help & Diagnostics") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(
                        "Report an issue",
                        caption: "Opens GitHub Issues with your MyUsage and macOS version pre-filled."
                    ) {
                        Button("Open") { SupportActions.openIssueWithDiagnostics() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    CardDivider()

                    SettingsRow(
                        "Copy crash log",
                        caption: crashLogStatus
                            ?? "Scans ~/Library/Logs/DiagnosticReports for the newest MyUsage crash."
                    ) {
                        Button("Copy") { copyLatestCrashLog() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func updateBanner(_ release: UpdateChecker.ReleaseInfo) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available — \(release.tag)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(updateBannerSubtitle(release))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                updateActionControl(release)
            }

            if case .downloading(let progress) = installer.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            shape.fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
        }
        .overlay {
            shape.strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.5)
        }
    }

    private func updateBannerSubtitle(_ release: UpdateChecker.ReleaseInfo) -> String {
        switch installer.state {
        case .idle: "Currently running v\(AppInfo.versionWithBuild)"
        case .downloading(let progress): "Downloading… \(Int(progress * 100))%"
        case .extracting: "Extracting…"
        case .ready: "Drag MyUsage.app into /Applications, then relaunch."
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private func updateActionControl(_ release: UpdateChecker.ReleaseInfo) -> some View {
        switch installer.state {
        case .idle:
            if release.zipAssetURL != nil {
                Button("Download") {
                    Task { await installer.install(release: release) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Open Release") {
                    NSWorkspace.shared.open(release.url)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .downloading, .extracting:
            ProgressView().controlSize(.small)
        case .ready:
            Button("Show in Finder") {
                installer.revealReady()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .failed:
            Button("Retry") {
                Task { await installer.install(release: release) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func copyLatestCrashLog() {
        switch SupportActions.copyLatestCrashLogToClipboard() {
        case .copied(let filename):
            crashLogStatus = "Copied \(filename) to clipboard."
        case .none:
            crashLogStatus = "No MyUsage crash logs found — nothing to report."
        case .failed(let message):
            crashLogStatus = "Could not read crash log: \(message)"
        }
    }
}

// MARK: - Support actions

private enum SupportActions {
    enum CrashLogResult {
        case copied(filename: String)
        case none
        case failed(String)
    }

    static func openIssueWithDiagnostics() {
        var components = URLComponents(string: "https://github.com/zchan0/MyUsage/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[bug] "),
            URLQueryItem(name: "body", value: issueBody())
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    static func copyLatestCrashLogToClipboard() -> CrashLogResult {
        let reportsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: reportsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("MyUsage") else { return false }
                let ext = url.pathExtension.lowercased()
                return ext == "ips" || ext == "crash"
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let latest = candidates.max(by: { a, b in
            (a.modificationDate ?? .distantPast) < (b.modificationDate ?? .distantPast)
        }) else {
            return .none
        }

        do {
            let contents = try String(contentsOf: latest, encoding: .utf8)
            let payload = "\(issueBody())\n\n---\n\n\(contents)"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            return .copied(filename: latest.lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func issueBody() -> String {
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        **What happened?**
        <!-- describe the issue -->

        **Steps to reproduce**
        1.
        2.

        **Expected vs actual**

        ---
        - MyUsage version: \(AppInfo.versionWithBuild)
        - macOS: \(macOS)
        """
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

#if DEBUG
#Preview("Settings · General") {
    let manager = PreviewFixtures.manager(providerCount: 4, gateway: .full)
    SettingsView(initialSection: .general)
        .environment(manager)
        .environment(UpdateChecker())
}

#Preview("Settings · Providers") {
    let manager = PreviewFixtures.manager(providerCount: 4, gateway: .full)
    SettingsView(initialSection: .providers)
        .environment(manager)
        .environment(UpdateChecker())
}

#Preview("Settings · Notifications · Dark") {
    let manager = PreviewFixtures.manager(providerCount: 4)
    SettingsView(initialSection: .notifications)
        .environment(manager)
        .environment(UpdateChecker())
        .preferredColorScheme(.dark)
}

#Preview("Settings · About") {
    let manager = PreviewFixtures.manager(providerCount: 4)
    SettingsView(initialSection: .about)
        .environment(manager)
        .environment(UpdateChecker())
}
#endif
