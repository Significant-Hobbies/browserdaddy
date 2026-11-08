import AppKit
import BrowserCore
import SwiftUI

struct BlockingView: View {
    @StateObject private var controller = BlockingController()
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
                                    .disabled(controller.busy)
                                Button(controller.enabled ? "Turn off filter" : "Enable filter") {
                                    controller.setEnabled(!controller.enabled)
                                }.disabled(controller.busy)
                                Button("Refresh status") { controller.refresh() }.disabled(controller.busy)
                            }
                        }
                        Text(controller.extensionBundled
                             ? "macOS will ask you to approve the system extension and network filter. Disabling the filter keeps your rules."
                             : "Your rules are saved locally. This build needs the signed BrowserDaddy network-filter extension before it can block connections.")
                            .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                        if !controller.error.isEmpty {
                            Text(controller.error).font(.callout).foregroundStyle(BrowserTheme.coral)
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
                BrowserBand(label: "COVERAGE & PRIVACY", subtitle: "Rules are not a guarantee of complete protection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The filter applies to identifiable connections in regular and private windows, and other apps. It does not save visited domains, URLs or a blocked-visit log.")
                        Text("Unknown domains and connections without an exposed hostname are allowed. Encrypted DNS, VPNs, connection reuse and browser networking can limit coverage. Sites missing from these lists, and adult content on shared sites, may remain accessible.")
                        Text("Cross-browser protection has not been verified on this Mac. Rule changes apply to new connections within a few seconds; existing connections may continue until closed.")
                    }.font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BrowserTheme.fog)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }

    private func addSite() { if controller.addSite(site) { site = "" } }
}
