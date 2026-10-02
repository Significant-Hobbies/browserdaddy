import SwiftUI
import BrowserCore

struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                access
                automation
                collection
                alerts
                tagging
                data
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var access: some View {
        BrowserBand(label: "HISTORY",
                    subtitle: "Read-only access to browser folders you choose") {
            VStack(alignment: .leading, spacing: 13) {
                Text("BrowserDaddy does not need Full Disk Access. Connect only the "
                     + "browser folders you want archived. Access is read-only and revocable; "
                     + "disconnecting a folder stops future reads but keeps existing archive rows.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                ForEach(model.browserAccess) { status in
                    browserRow(status)
                }
                HStack {
                    Spacer()
                    Button("Connect all detected browsers") {
                        model.connectAllBrowsers()
                    }
                }
                if !model.browserAccessError.isEmpty {
                    Text(model.browserAccessError)
                        .font(.caption).foregroundStyle(BrowserTheme.coral)
                }
            }
        }
    }

    private func browserRow(_ status: BrowserAccessStatus) -> some View {
        HStack(spacing: 10) {
            Circle().fill(accessColor(status.state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.kind.displayName).font(.callout.weight(.semibold))
                    .foregroundStyle(BrowserTheme.ink)
                Text(accessLabel(status)).font(.caption)
                    .foregroundStyle(BrowserTheme.secondaryInk)
                    .lineLimit(1).truncationMode(.middle)
                    .help(accessLabel(status))
            }
            Spacer()
            Button(accessButtonTitle(status.state)) {
                model.connectBrowser(status.kind)
            }
            if case .connected = status.state {
                Button("Disconnect") { model.removeBrowser(status.kind) }
            }
        }
        .padding(.vertical, 2)
    }

    private var automation: some View {
        BrowserBand(label: "TABS",
                    subtitle: "Browser automation and Safari extension access") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Chrome tabs are read only from windows verified "
                     + "as normal. Safari tabs come from its optional extension, "
                     + "which excludes Private Browsing before sharing URLs. "
                     + "Anything unverifiable stays app-only.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                ForEach(FocusWatcher.tabCapableBrowsers.values.sorted(),
                        id: \.self) { name in
                    HStack {
                        Circle()
                            .fill(dotColor(model.automation[name]))
                            .frame(width: 8, height: 8)
                        Text(name).font(.callout)
                            .foregroundStyle(BrowserTheme.ink)
                        Spacer()
                        Text(stateLabel(model.automation[name]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Circle().fill(BrowserTheme.mintInk.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text("Safari extension").font(.callout)
                        .foregroundStyle(BrowserTheme.ink)
                    Spacer()
                    Button("Open Safari Extensions") {
                        SafariTabsBridge.openPreferences()
                    }
                }
                HStack {
                    Spacer()
                    Button("Re-check") { model.refreshPermissions() }
                    Button("Open Automation Settings") {
                        Permissions.openAutomationSettings()
                    }
                }
            }
        }
    }

    private var collection: some View {
        BrowserBand(label: "COLLECTION",
                    subtitle: "What runs while the app is alive") {
            VStack(alignment: .leading, spacing: 13) {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .tint(BrowserTheme.mintInk)
                HStack(spacing: 12) {
                    Button(model.extracting ? "Syncing…" : "Sync history now") {
                        model.runExtract()
                    }
                    .buttonStyle(DaddyButtonStyle(prominent: true))
                    .disabled(model.extracting)
                    if model.extracting { ProgressView().controlSize(.small) }
                }
                if !model.extractLog.isEmpty {
                    Divider().overlay(BrowserTheme.divider)
                    ForEach(model.extractLog, id: \.self) {
                        Text($0).font(.caption.monospaced())
                            .foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
            }
        }
    }

    private var alerts: some View {
        BrowserBand(label: "ALERTS",
                    subtitle: "Local notifications on measured attention — nothing leaves the Mac") {
            AlertSettingsView()
        }
    }

    private var tagging: some View {
        BrowserBand(label: "TAGGING",
                    subtitle: "Optional topic classification via classifier.dev") {
            VStack(alignment: .leading, spacing: 10) {
                Text(Classifier.disclosure)
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                Toggle("Allow sending browsing text to classifier.dev", isOn: Binding(
                    get: { model.classifyOptin },
                    set: { model.setClassifyOptin($0) }))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(BrowserTheme.ink)
                HStack(spacing: 12) {
                    Button(model.classifying ? "Tagging…" : "Tag new domains + pages") {
                        model.runClassification()
                    }
                    .disabled(model.classifying || !model.classifyOptin)
                    .buttonStyle(DaddyButtonStyle(prominent: true))
                    if model.classifying {
                        ProgressView().controlSize(.small)
                    }
                    if !model.classifySummary.isEmpty {
                        Text(model.classifySummary).font(.caption)
                            .foregroundStyle(BrowserTheme.mintInk)
                    }
                }
                if !model.classifyLog.isEmpty {
                    ForEach(model.classifyLog.suffix(6), id: \.self) {
                        Text($0).font(.caption.monospaced())
                            .foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
            }
        }
    }

    private var data: some View {
        BrowserBand(label: "DATA",
                    subtitle: "Local archive location · external tagging stays optional") {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(BrowserTheme.mintInk)
                Text(ArchiveStore.defaultURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(BrowserTheme.secondaryInk)
                    .textSelection(.enabled)
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [ArchiveStore.defaultURL])
                }
            }
        }
    }

    private func dotColor(_ s: Permissions.AutomationState?) -> Color {
        switch s {
        case .granted: BrowserTheme.mintInk
        case .denied: BrowserTheme.coral
        default: BrowserTheme.secondaryInk.opacity(0.5)
        }
    }

    private func stateLabel(_ s: Permissions.AutomationState?) -> String {
        switch s {
        case .granted: "granted"
        case .denied: "denied — enable in Settings"
        case .notRunning: "browser not running"
        default: "unknown"
        }
    }

    private func accessColor(_ state: BrowserAccessState) -> Color {
        if case .connected = state { return BrowserTheme.mintInk }
        if case .needsAccess = state { return BrowserTheme.coral }
        return BrowserTheme.secondaryInk.opacity(0.5)
    }

    private func accessLabel(_ status: BrowserAccessStatus) -> String {
        switch status.state {
        case .notConnected:
            "Not connected — \(status.kind.connectDirections)"
        case .connected(let path): path
        case .needsAccess(let message): message
        }
    }

    private func accessButtonTitle(_ state: BrowserAccessState) -> String {
        switch state {
        case .notConnected: "Connect"
        case .connected: "Change"
        case .needsAccess: "Reconnect"
        }
    }
}
