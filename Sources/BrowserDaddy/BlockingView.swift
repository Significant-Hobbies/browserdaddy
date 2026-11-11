import AppKit
import BrowserCore
import SwiftUI

struct BlockingView: View {
    @StateObject private var controller: BlockingController
    @StateObject private var protectionCheck: ProtectionCheckModel
    @State private var site = ""

    init(controller: BlockingController = .shared, protectionCheck: ProtectionCheckModel = ProtectionCheckModel()) {
        _controller = StateObject(wrappedValue: controller)
        _protectionCheck = StateObject(wrappedValue: protectionCheck)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                BrowserBand(label: "BLOCKING", subtitle: "One set of rules, including private windows") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(controller.status, systemImage: controller.enabled ? "shield.lefthalf.filled" : "shield")
                            .font(.headline)
                        if controller.extensionBundled {
                            HStack {
                                Button(controller.enabled ? "Apply protected rules" : "Enable protected filter") {
                                    controller.enable()
                                }.disabled(controller.busy || !controller.ready)
                                Button("Refresh status") { controller.refresh() }.disabled(controller.busy)
                            }
                        }
                        Text(controller.extensionBundled
                             ? "macOS will ask you to approve the system extension and network filter. Protection is committed in this app. You can add blocked websites; changes to protected settings require deliberate maintenance requested through Codex chat. Invalid rules block outgoing traffic until valid protected rules arrive."
                             : "Your rules are saved locally. This build needs the signed BrowserDaddy network-filter extension before it can block connections.")
                            .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                        if !controller.error.isEmpty {
                            Text(controller.error).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.loadError.isEmpty && controller.loadError != controller.error {
                            Text(controller.loadError).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.nativeRepairWarning.isEmpty && controller.nativeRepairWarning != controller.error {
                            Text(controller.nativeRepairWarning).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.nativeRecoveryNote.isEmpty {
                            Text(controller.nativeRecoveryNote).font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                        }
                    }
                }
                protectionCheckBand
                BrowserBand(label: "CATEGORIES", subtitle: "Block known domains using offline lists") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(BlockingCategory.allCases, id: \.self) { category in
                            HStack {
                                Label(category.title, systemImage: "checkmark.shield.fill")
                                Spacer()
                                Text("\((controller.configuration.lists[category]?.count ?? 0).formatted()) domains")
                                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                            }
                        }
                        Text("Bundled lists: ShadowWhisperer/BlockLists · bundled snapshot d2f4083 · Unlicense. Both complete lists are protected, stay on this Mac and do not update automatically.")
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
                .disabled(!controller.ready || controller.busy)
                BrowserBand(label: "STRICT PROTECTION", subtitle: "System-wide · may interrupt legitimate apps") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Outgoing connections with hidden destinations are blocked", systemImage: "checkmark.shield.fill")
                        Text("Applies to every app, including private browser windows. Hidden destinations, IP-only connections, DNS lookups and local app connections can be blocked. This may stop all internet access or entire browsers. Protected settings require assisted maintenance through Codex chat. Existing connections may continue until closed.")
                            .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }.disabled(!controller.ready || controller.busy)
                BrowserBand(label: "SITES", subtitle: "A domain rule also blocks its subdomains") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("example.com", text: $site).textFieldStyle(.roundedBorder)
                                .onSubmit { addSite() }
                            Button("Add website") { addSite() }.disabled(site.isEmpty)
                        }
                        ForEach(controller.configuration.sites.sorted(by: { $0.value < $1.value }), id: \.self) { host in
                            HStack {
                                Text(host.value).font(.callout.monospaced())
                                Spacer()
                            }
                        }
                        if controller.configuration.sites.isEmpty {
                            Text("Add any other websites you want blocked.")
                                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                        }
                    }
                }
                .disabled(!controller.ready || controller.busy)
                BrowserBand(label: "COVERAGE & PRIVACY", subtitle: "Rules are not a guarantee of complete protection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The filter applies to identifiable connections in regular and private windows, and other apps. It does not save visited domains, URLs or a blocked-visit log.")
                        Text("Sites missing from the category lists, and adult content on shared sites, may remain accessible. Strict protection always blocks outgoing connections whose destination cannot be identified. Encrypted DNS, browser networking, VPNs and connection reuse can limit coverage.")
                        Text("A device administrator can disable or remove the system extension through macOS or Recovery. BrowserDaddy does not change those operating-system controls.")
                        Text("Cross-browser protection has not been verified on this Mac. Saved rule changes are sent to macOS when the filter is configured. Delivery and enforcement require runtime verification; existing connections may continue until closed.")
                    }.font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BrowserTheme.fog)
        .onAppear { protectionCheck.startObservingNetwork() }
        .onDisappear { protectionCheck.stopObservingNetwork() }
        .onChange(of: controller.configuration) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.enabled) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.ready) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.busy) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.status) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.configuration.sites) { _, sites in
            if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), sites.contains(host) {
                site = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            protectionCheck.invalidate()
        }
    }

    private var protectionCheckBand: some View {
        BrowserBand(label: "CHECK PROTECTION", subtitle: "Four samples from this app's network path") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Only when you click Check protection, BrowserDaddy sends one HTTPS HEAD request to each destination below. These hosts receive your IP address and standard connection metadata. No browsing history is read or sent; responses are not saved.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                ForEach(ProtectionCheckTarget.allCases) { target in
                    HStack {
                        Text(target.rawValue).font(.callout.monospaced())
                        Text(target.isProtected ? "Protected sample" : "Allowed control")
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                        Spacer()
                        Text(protectionCheck.observations[target]?.label ?? (protectionCheck.isRunning ? "Checking…" : "—"))
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
                if controller.configuration.blocks(hostname: ProtectionCheckTarget.allowed.rawValue, outgoing: true) {
                    Text("Your rules block example.com. The allowed control will be inconclusive.")
                        .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
                HStack {
                    Button("Check protection") {
                        protectionCheck.start(configuration: controller.configuration, eligible: canCheckProtection)
                    }.disabled(!canCheckProtection || protectionCheck.isRunning)
                    if protectionCheck.isRunning {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { protectionCheck.cancel() }
                    }
                }
                protectionCheckResult
                Text("A failed request never proves blocking. This checks BrowserDaddy only, not Chrome, private windows, other apps or all content. Results can change as rules, connections and networks change.")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
            }
        }
    }

    private var canCheckProtection: Bool {
        controller.ready && !controller.busy && controller.enabled && controller.extensionBundled
    }

    @ViewBuilder private var protectionCheckResult: some View {
        switch protectionCheck.state {
        case .idle:
            if !canCheckProtection {
                Text("Enable the bundled protected filter before checking.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            }
        case .running:
            Text("Checking four destinations · up to 8 seconds")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
        case .finished(let report):
            Text(report.summary).font(.callout)
                .foregroundStyle(report.assessment == .protectedReachable ? BrowserTheme.coral : BrowserTheme.secondaryInk)
            Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
        case .cancelled:
            Text("Check cancelled. No conclusion was recorded.")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
        case .stale:
            Text("The previous check is stale. Run a new check for current observations.")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
        }
    }

    private func addSite() {
        if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), controller.configuration.sites.contains(host) {
            site = ""
        } else { _ = controller.addSite(site) }
    }
}
