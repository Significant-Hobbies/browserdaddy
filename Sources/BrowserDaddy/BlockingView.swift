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
                                Button("Set up system filter") { controller.activate() }
                                    .disabled(controller.busy || !controller.ready)
                                Button(controller.enabled ? "Turn off filter" : "Enable filter") {
                                    controller.setEnabled(!controller.enabled)
                                }.disabled(controller.busy || (!controller.ready && !controller.enabled))
                                Button("Refresh status") { controller.refresh() }.disabled(controller.busy)
                                if controller.enabled && controller.ready {
                                    Button("Apply saved rules") { controller.setEnabled(true) }.disabled(controller.busy)
                                }
                            }
                        }
                        Text(controller.extensionBundled
                             ? "macOS will ask you to approve the system extension and network filter. If the filter starts without valid rules, outgoing traffic is blocked until valid rules arrive or you turn off the filter. Disabling the filter keeps your rules."
                             : "Your rules are saved locally. This build needs the signed BrowserDaddy network-filter extension before it can block connections.")
                            .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                        if !controller.error.isEmpty {
                            Text(controller.error).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.loadError.isEmpty && controller.loadError != controller.error {
                            Text(controller.loadError).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                    }
                }
                BrowserBand(label: "CATEGORIES", subtitle: "Block known domains using offline lists") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(BlockingCategory.allCases, id: \.self) { category in
                            HStack {
                                Toggle(category.title, isOn: Binding(
                                    get: { controller.configuration.categories.contains(category) },
                                    set: { selected in
                                        var value = controller.configuration
                                        if selected { value.categories.insert(category) }
                                        else { value.categories.remove(category) }
                                        controller.save(value)
                                    }))
                                    .toggleStyle(.checkbox)
                                Spacer()
                                Text("\((controller.configuration.lists[category]?.count ?? 0).formatted()) domains")
                                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                                Button("Replace list…") { controller.importList(category) }
                            }
                        }
                        Text("Bundled lists: ShadowWhisperer/BlockLists · bundled snapshot d2f4083 · Unlicense. Lists stay on this Mac and do not update automatically. Replacement lists are yours to verify.")
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
                .disabled(!controller.ready || controller.busy)
                BrowserBand(label: "STRICT PROTECTION", subtitle: "System-wide · may interrupt legitimate apps") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Block outgoing connections with hidden destinations", isOn: Binding(
                            get: { controller.configuration.strictUnknownDestinations },
                            set: { selected in
                                var value = controller.configuration
                                value.strictUnknownDestinations = selected
                                controller.save(value)
                            }))
                            .toggleStyle(.checkbox)
                        Text("Applies to every app, including private browser windows. Connections without a usable domain name, including IP-only connections, are blocked. This can break websites, VPNs, updates and other apps. Turn off the filter to recover. Existing connections may continue until closed.")
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
                                Button("Remove") {
                                    var value = controller.configuration
                                    value.sites.remove(host)
                                    controller.save(value)
                                }
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
                        Text("Sites missing from the category lists, and adult content on shared sites, may remain accessible. Strict protection blocks outgoing connections whose destination cannot be identified; otherwise those connections are allowed. VPNs and connection reuse can limit coverage.")
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
