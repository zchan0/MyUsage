import SwiftUI

struct UsagePopover: View {
    let manager: UsageManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedProviderID: ProviderID?

    private static let selectionKey = "selectedPopoverProviderID"

    init(manager: UsageManager) {
        self.manager = manager
        let saved = UserDefaults.standard.string(forKey: Self.selectionKey).map(ProviderID.init(rawValue:))
        let tracked = manager.iconTrackProvider.isEmpty ? nil : ProviderID(rawValue: manager.iconTrackProvider)
        let firstEnabled = manager.orderedProviders.first(where: \.isEnabled)?.id
        _selectedProviderID = State(initialValue: Self.debugSelection ?? saved ?? tracked ?? firstEnabled)
    }

    #if DEBUG
    init(manager: UsageManager, previewSelection: ProviderID) {
        self.manager = manager
        _selectedProviderID = State(initialValue: previewSelection)
        persistsSelection = false
    }
    #endif

    var body: some View {
        let providers = manager.orderedProviders.filter(\.isEnabled)
        let active = providers.first { $0.id == selectedProviderID } ?? providers.first
        VStack(spacing: 0) {
            if let active {
                if providers.count >= 2 {
                    ProviderTabBar(
                        items: providers.map { .init(provider: $0, needsAttention: needsAttention($0)) },
                        selection: Binding(get: { active.id }, set: { selectedProviderID = $0 })
                    )
                }

                PopoverPage {
                    ProviderDeck(provider: active)
                        .id(active.id)
                        .transition(.asymmetric(
                            insertion: .offset(y: 3).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                .animation(PopoverMotion.selection, value: active.id)
            } else {
                emptyState
            }

            PopoverFooterBar(provider: active)
        }
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: selectedProviderID) { _, id in
            guard persistsSelection else { return }
            UserDefaults.standard.set(id?.rawValue, forKey: Self.selectionKey)
        }
    }

    private func needsAttention(_ provider: any UsageProvider) -> Bool {
        switch provider.payload {
        case .builtin(let snapshot):
            guard case .builtin(let kind) = provider.source else { return false }
            return CapacityFocus.metrics(providerKind: kind, snapshot: snapshot)
                .contains(where: \.requiresOverviewAttention)
        case .gateway(let snapshot):
            return snapshot.summary.issue == nil && (snapshot.summary.value?.percentUsed ?? 0) >= 90
        case nil:
            return false
        }
    }

    private var emptyState: some View {
        let palette = PopoverPalette(colorScheme)
        return GlassSheet {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundStyle(palette.inkTertiary)
                Text("No providers detected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("Enable a provider or add a gateway in Settings to get started.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var persistsSelection = Self.allowsPersistence

    private static var allowsPersistence: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["MYUSAGE_PREVIEW_PROVIDERS"] == nil && environment["MYUSAGE_TAB"] == nil
    }

    private static var debugSelection: ProviderID? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let tab = environment["MYUSAGE_TAB"] {
            if tab == "gateway" {
                let index = environment["MYUSAGE_PREVIEW_GATEWAY_INDEX"].flatMap(Int.init) ?? 0
                return .gateway(GatewayPreviewFixtures.id(index: max(0, min(index, 49))))
            }
            return ProviderID.migrated(tab)
        }
        #endif
        return nil
    }
}

#if DEBUG
#Preview("Capsule dock · Codex") {
    let manager = PreviewFixtures.manager(providerCount: 4)
    UsagePopover(manager: manager, previewSelection: .builtin(.codex))
        .environment(manager)
        .environment(UpdateChecker())
}

#Preview("Capsule dock · Claude · Dark") {
    let manager = PreviewFixtures.manager(providerCount: 4)
    UsagePopover(manager: manager, previewSelection: .builtin(.claude))
        .environment(manager)
        .environment(UpdateChecker())
        .preferredColorScheme(.dark)
}

#Preview("Claude · Single provider") {
    let manager = PreviewFixtures.manager(providerCount: 1)
    UsagePopover(manager: manager, previewSelection: .builtin(.claude))
        .environment(manager)
        .environment(UpdateChecker())
}
#endif
