import AppKit
import BrowserCore
import SwiftUI

struct BlockingView: View {
    @StateObject private var controller = BlockingController.shared
    @State private var site = ""

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
                    }
                }
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
        .onChange(of: controller.configuration.sites) { _, sites in
            if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), sites.contains(host) {
                site = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }

    private func addSite() {
        if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), controller.configuration.sites.contains(host) {
            site = ""
        } else { _ = controller.addSite(site) }
    }
}
