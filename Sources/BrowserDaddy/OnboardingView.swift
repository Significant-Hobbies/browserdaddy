import SwiftUI
import BrowserCore

/// First-run flow: grant access, understand what's collected, opt into
/// optional topic classification, then land on the app.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 26) {
                header
                access
                honesty
                tagging
                footer
            }
            .padding(40)
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 18)
                .fill(BrowserTheme.surface))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserTheme.fog)
        .onAppear { model.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DaddyArtwork(brand: true).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("browserdaddy").font(.title2.weight(.bold))
                    .foregroundStyle(BrowserTheme.ink)
                Text("archive your history. watch your attention.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCESS").font(.caption.weight(.semibold))
                .foregroundStyle(BrowserTheme.secondaryInk)
            Text("Choose only the browser folders you want archived. Access is "
                 + "read-only, can be removed later, and never includes the rest of your disk.")
                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
            Text("For each browser: Connect → the panel opens at the right "
                 + "folder → choose it → “Connect read-only”.")
                .font(.caption).foregroundStyle(BrowserTheme.mintInk)
            Button("Connect all detected browsers") {
                model.connectAllBrowsers()
            }
            .buttonStyle(DaddyButtonStyle(prominent: true))
            .disabled(model.browserAccess.isEmpty)
            ForEach(model.browserAccess) { status in
                row(ok: isConnected(status.state), title: status.kind.displayName,
                    body: accessLabel(status),
                    actionTitle: isConnected(status.state) ? "Change" : "Connect",
                    action: { model.connectBrowser(status.kind) })
            }
            if !model.browserAccessError.isEmpty {
                Text(model.browserAccessError).font(.caption)
                    .foregroundStyle(BrowserTheme.coral)
            }
            row(
                ok: true,
                title: "Browser automation",
                body: "Chromium-family tab capture verifies a normal window before "
                      + "reading URLs. Browsers that can't prove window mode record "
                      + "app-level time only.",
                actionTitle: nil, action: nil)
        }
    }

    private var honesty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT IT DOES").font(.caption.weight(.semibold))
                .foregroundStyle(BrowserTheme.secondaryInk)
            Label("Archives history permanently — survives browser pruning.",
                  systemImage: "archivebox")
            Label("Records focused apps and verified normal Chrome tabs after you start.",
                  systemImage: "eye")
            Label("Private browsing is never reconstructed.",
                  systemImage: "hand.raised")
            Label("The archive stays in a SQLite file on this Mac.",
                  systemImage: "lock.shield")
        }
        .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
    }

    private var tagging: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPTIONAL — TOPIC TAGGING").font(.caption.weight(.semibold))
                .foregroundStyle(BrowserTheme.secondaryInk)
            Text(Classifier.disclosure)
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            Toggle("Allow sending browsing text to classifier.dev", isOn: Binding(
                get: { model.classifyOptin },
                set: { model.setClassifyOptin($0) }))
                .toggleStyle(.checkbox)
                .foregroundStyle(BrowserTheme.ink)
            if model.classifyOptin {
                HStack(spacing: 12) {
                    Button(model.classifying ? "Tagging…" : "Tag now") {
                        model.runClassification()
                    }
                    .disabled(model.classifying)
                    .buttonStyle(PrimaryActionButtonStyle())
                    if !model.classifySummary.isEmpty {
                        Text(model.classifySummary).font(.caption)
                            .foregroundStyle(BrowserTheme.mintInk)
                    }
                }
                if !model.classifyLog.isEmpty {
                    Text(model.classifyLog.suffix(4).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(model.hasConnectedBrowser ? "Start watching" : "Continue without history") {
                model.finishOnboarding()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .controlSize(.large)
        }
    }

    private func isConnected(_ state: BrowserAccessState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private func accessLabel(_ status: BrowserAccessStatus) -> String {
        switch status.state {
        case .notConnected: "Not connected — \(status.kind.connectDirections)."
        case .connected(let path): path
        case .needsAccess(let message): message
        }
    }

    private func row(ok: Bool, title: String, body: String,
                     actionTitle: String?,
                     action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(ok ? BrowserTheme.mintInk : BrowserTheme.coral)
                .frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                    .foregroundStyle(BrowserTheme.ink)
                Text(body).font(.caption)
                    .foregroundStyle(BrowserTheme.secondaryInk)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(DaddyButtonStyle())
            }
        }
    }
}
