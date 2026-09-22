import SwiftUI

struct GatewayEditorTarget: Identifiable {
    let id = UUID()
    let connection: GatewayConnection?
}

struct GatewayConnectionEditor: View {
    let connection: GatewayConnection?
    @Environment(UsageManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var key = ""
    @State private var userID = ""
    @State private var showUserID = false
    @State private var inspection: GatewayConnectionCheck?
    @State private var selectedScope: GatewayScope?
    @State private var task: Task<Void, Never>?
    @State private var revision = UUID()
    @State private var checking = false
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(connection == nil ? "Add Gateway" : "Edit Gateway")
                .font(.system(size: 14, weight: .semibold))
            SettingsCard {
                SettingsRow("Vendor") { Text("LiteLLM").foregroundStyle(.secondary) }
                CardDivider()
                SettingsRow("Name") { TextField("Company gateway", text: $name).frame(width: 280) }
                CardDivider()
                SettingsRow("Base URL") { TextField("https://ai.example.com", text: $host).frame(width: 280) }
                CardDivider()
                SettingsRow("API key", caption: connection == nil ? "Stored in this Mac's Keychain." : "Leave empty to keep the saved key.") {
                    SecureField("API key", text: $key).frame(width: 280)
                }
                if showUserID {
                    CardDivider()
                    SettingsRow("User ID", caption: "Only needed if your key cannot identify its user.") {
                        TextField("LiteLLM user ID", text: $userID).frame(width: 280)
                    }
                }
                if let inspection, !inspection.usableScopes.isEmpty {
                    CardDivider()
                    SettingsRow("Usage for", caption: selectedScope?.kind == .user
                                ? "Your account includes its linked keys." : "Only this API key's usage.") {
                        if inspection.usableScopes.count > 1 {
                            Picker("Usage for", selection: $selectedScope) {
                                ForEach(inspection.usableScopes, id: \.scope) { result in
                                    Text(result.scope.label).tag(Optional(result.scope))
                                }
                            }.labelsHidden().frame(width: 180)
                        } else {
                            Text(inspection.usableScopes[0].scope.label).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Button("Check Usage Access", action: check).disabled(checking || name.trimmingCharacters(in: .whitespaces).isEmpty || host.isEmpty)
                if checking { ProgressView().controlSize(.small) }
                Text(resultMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.red) }
            Divider()
            HStack {
                if connection != nil {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if inspection != nil && selectedResult == nil {
                    Button("Save for Later") { save(verified: false) }.disabled(checking)
                }
                Button(connection == nil ? "Add Provider" : "Save") { save(verified: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || !canSave)
            }
        }
        .padding(20).frame(width: 540)
        .onAppear {
            name = connection?.name ?? ""; host = connection?.baseURL.absoluteString ?? ""
            userID = connection?.explicitUserID ?? ""; selectedScope = connection?.scope
            showUserID = connection?.explicitUserID != nil
        }
        .onChange(of: host) { _, _ in invalidate() }
        .onChange(of: key) { _, _ in invalidate() }
        .onChange(of: userID) { _, _ in invalidate() }
        .onDisappear { task?.cancel(); key = "" }
        .confirmationDialog("Remove this gateway?", isPresented: $confirmRemove) {
            Button("Remove Gateway", role: .destructive) {
                do { if let connection { try manager.removeGateway(connection) }; dismiss() }
                catch { message = error.localizedDescription }
            }
        } message: { Text("This removes the local connection and saved key. The server key is unchanged.") }
    }

    private var selectedResult: GatewayScopeCheck? { inspection?.usableScopes.first { $0.scope == selectedScope } }
    private var onlyNameChanged: Bool {
        guard let connection else { return false }
        return host == connection.baseURL.absoluteString && key.isEmpty && userID == (connection.explicitUserID ?? "")
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (selectedResult != nil || onlyNameChanged) }
    private var resultMessage: String {
        if let result = selectedResult {
            if let issue = result.history.issue, issue != .notChecked { return "Usage available · Model history: \(issue.message)" }
            return "Usage access verified · \(result.scope.label)"
        }
        if let inspection { return inspection.issues.first?.message ?? inspection.scopes.first?.summary.issue?.message ?? "Usage could not be verified." }
        return "Reads usage from your gateway."
    }
    private func invalidate() {
        revision = UUID(); task?.cancel(); task = nil; checking = false; inspection = nil; message = nil
    }
    private func draft() throws -> GatewayConnection {
        let url = try GatewayAddress.normalize(host)
        if let connection, connection.baseURL != url, key.isEmpty { throw GatewayStoreError.newKeyRequired }
        var draft = connection ?? GatewayConnection(name: name, baseURL: url)
        draft.name = name; draft.baseURL = url
        draft.explicitUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userID
        draft.scope = selectedScope
        return draft
    }
    private func check() {
        invalidate()
        do {
            let draft = try draft()
            let secret = key.isEmpty ? try manager.gatewayStore.credentials.read(draft.credentialReference) : key
            let current = revision
            checking = true
            task = Task {
                do {
                    let result = try await GatewayAdapters.adapter(for: draft.vendor)
                        .checkConnection(.init(connection: draft, apiKey: secret))
                    guard revision == current, !Task.isCancelled else { return }
                    inspection = result
                    if !result.usableScopes.contains(where: { $0.scope == selectedScope }) { selectedScope = result.preferredScope }
                    showUserID = result.issues.contains(.identityUnknown)
                    checking = false
                } catch is CancellationError { }
                catch {
                    guard revision == current else { return }
                    checking = false; message = (error as? GatewayIssue)?.message ?? "Could not check usage access."
                }
            }
        } catch { message = (error as? GatewayIssue)?.message ?? error.localizedDescription }
    }
    private func save(verified: Bool) {
        do {
            var draft = try draft()
            draft.scope = verified ? (selectedResult?.scope ?? connection?.scope) : nil
            try manager.saveGateway(draft, newKey: key.isEmpty ? nil : key, initial: verified ? selectedResult : nil)
            dismiss()
        } catch { message = (error as? GatewayIssue)?.message ?? error.localizedDescription }
    }
}
