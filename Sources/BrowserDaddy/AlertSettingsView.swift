import SwiftUI
import BrowserCore

/// Shared alert-threshold editor — the Permissions ALERTS band and the
/// Settings window (⌘,) both host this.
struct AlertSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var capHost = ""
    @State private var capMinutes = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle("Notify on attention thresholds", isOn: Binding(
                get: { model.alertConfig.enabled },
                set: { var c = model.alertConfig; c.enabled = $0
                       model.setAlertConfig(c) }))
                .tint(BrowserTheme.mintInk)
                .foregroundStyle(BrowserTheme.ink)
            if model.alertConfig.enabled {
                capRow("Focused minutes per day", \.dailyMinutes)
                capRow("Minutes on one page before a nudge", \.streakMinutes)
                capRow("Agent-driven minutes per day", \.agentMinutes)
                Text("Agent time is counted separately: it needs Chromium tab "
                     + "churn with no input — other browsers can't qualify, "
                     + "and it doesn't count toward your focused cap.")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                siteCaps
            }
        }
    }

    private func capRow(_ label: String,
                        _ keyPath: WritableKeyPath<AlertConfig, Int>) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(BrowserTheme.ink)
            Spacer()
            Text(model.alertConfig[keyPath: keyPath] == 0
                 ? "off" : "\(model.alertConfig[keyPath: keyPath]) min")
                .font(.caption.monospacedDigit())
                .foregroundStyle(BrowserTheme.secondaryInk)
                .frame(minWidth: 56, alignment: .trailing)
            Stepper("", value: Binding(
                get: { model.alertConfig[keyPath: keyPath] },
                set: { var c = model.alertConfig; c[keyPath: keyPath] = $0
                       model.setAlertConfig(c) }),
                in: 0...480, step: 5)
                .labelsHidden()
        }
    }

    private var siteCaps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PER-SITE DAILY CAPS").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.alertConfig.siteCaps.sorted(by: { $0.key < $1.key }),
                    id: \.key) { host, mins in
                HStack {
                    Text(host).font(.callout.monospaced())
                        .foregroundStyle(BrowserTheme.ink)
                    Spacer()
                    Text("\(mins) min").font(.caption.monospacedDigit())
                        .foregroundStyle(BrowserTheme.secondaryInk)
                    Button("Remove") {
                        var c = model.alertConfig
                        c.siteCaps.removeValue(forKey: host)
                        model.setAlertConfig(c)
                    }
                }
            }
            HStack {
                TextField("host (e.g. youtube.com)", text: $capHost)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Stepper("\(capMinutes) min", value: $capMinutes,
                        in: 5...480, step: 5)
                Button("Add") {
                    let raw = capHost
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !raw.isEmpty else { return }
                    // Accept pasted URLs too — store host[:port], which is
                    // exactly what focus rows carry.
                    var host = raw
                    if let parsed = URL(string: raw.contains("://")
                                        ? raw : "https://" + raw),
                       let h = parsed.host, !h.isEmpty {
                        host = parsed.port.map { "\(h):\($0)" } ?? h
                    }
                    var c = model.alertConfig
                    c.siteCaps[host] = capMinutes
                    model.setAlertConfig(c)
                    capHost = ""
                }
                .disabled(capHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Site caps use captured tab URLs — Chromium browsers only; "
                 + "a cap covers the whole site including subdomains.")
                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
        }
    }
}
