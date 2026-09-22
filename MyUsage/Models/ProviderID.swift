import Foundation
import SwiftUI

/// Persistent instance identity; a vendor can own any number of instances.
struct ProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func builtin(_ kind: ProviderKind) -> Self { .init(rawValue: "builtin:\(kind.rawValue)") }
    static func gateway(_ id: UUID) -> Self { .init(rawValue: "gateway:\(id.uuidString.lowercased())") }
    static func migrated(_ raw: String) -> Self {
        ProviderKind(rawValue: raw).map(Self.builtin) ?? .init(rawValue: raw)
    }
}

enum GatewayVendor: String, Codable, Sendable, CaseIterable {
    case litellm
    var displayName: String { "LiteLLM" }
}

enum ProviderSource: Equatable, Sendable {
    case builtin(ProviderKind)
    case gateway(GatewayVendor)

    var displayName: String {
        switch self {
        case .builtin(let kind): kind.displayName
        case .gateway(let vendor): vendor.displayName
        }
    }
    func usageTint(for scheme: ColorScheme) -> Color {
        switch self {
        case .builtin(let kind): kind.usageTint(for: scheme)
        case .gateway: Color.teal.opacity(scheme == .dark ? 0.7 : 0.8)
        }
    }
}

enum ProviderPayload {
    case builtin(UsageSnapshot)
    case gateway(GatewaySnapshot)
}
