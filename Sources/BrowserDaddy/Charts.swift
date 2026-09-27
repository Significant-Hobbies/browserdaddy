import SwiftUI
import BrowserCore

/// Stable per-browser colors.
enum BrowserColor {
    static func forBrowser(_ name: String) -> Color {
        switch name.lowercased() {
        case "chrome": BrowserTheme.mintInk
        case "safari": BrowserTheme.cyan
        case "brave": BrowserTheme.amber
        case "edge": BrowserTheme.blue
        case "firefox": BrowserTheme.coral
        default: BrowserTheme.secondaryInk
        }
    }
}

/// Daily visits stacked by browser — the archive-over-time view.
/// The Safari→Chrome migration is visible in the color mix.
struct DailyStackedBars: View {
    let series: [ReportEngine.DayPoint]
    var height: CGFloat = 140
    @State private var hoverDay: Int?

    private var prepped: (days: [String], browsers: [String],
                          byDay: [String: [String: Int64]], max: Int64) {
        let days = Array(Set(series.map(\.date))).sorted()
        let browsers = Array(Set(series.map(\.browser))).sorted()
        var byDay: [String: [String: Int64]] = [:]
        for p in series { byDay[p.date, default: [:]][p.browser] = p.count }
        let mx = max(1, days.map { d in
            byDay[d, default: [:]].values.reduce(0, +) }.max() ?? 1)
        return (days, browsers, byDay, mx)
    }

    var body: some View {
        let (days, browsers, byDay, mx) = prepped
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            ForEach(browsers, id: \.self) { b in
                                let c = byDay[d, default: [:]][b] ?? 0
                                if c > 0 {
                                    Rectangle()
                                        .fill(BrowserColor.forBrowser(b))
                                        .frame(height: max(0.5,
                                            CGFloat(c) / CGFloat(mx) * height))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(hoverDay == nil || hoverDay == i ? 1 : 0.45)
                        .overlay(alignment: .bottom) {
                            if hoverDay == i {
                                Rectangle().stroke(BrowserTheme.ink,
                                                   lineWidth: 1)
                                    .frame(height: height)
                            }
                        }
                    }
                }
                .frame(height: height)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p):
                        let frac = p.x / max(1, g.size.width)
                        hoverDay = max(0, min(days.count - 1,
                            Int(frac * CGFloat(days.count))))
                    case .ended:
                        hoverDay = nil
                    }
                }
            }
            .frame(height: height)

            // live readout for the hovered column
            if let i = hoverDay, days.indices.contains(i) {
                let d = days[i]
                Text("\(d) — " + browsers.compactMap { b in
                    let c = byDay[d, default: [:]][b] ?? 0
                    return c > 0 ? "\(b) \(c.formatted())" : nil
                }.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(BrowserTheme.ink)
            }

            // axis: month ticks + browser legend
            HStack {
                ForEach(monthTicks(days), id: \.self) { m in
                    Text(m).font(.system(size: 8))
                        .foregroundStyle(BrowserTheme.secondaryInk)
                    Spacer()
                }
            }
            HStack(spacing: 12) {
                ForEach(browsers, id: \.self) { b in
                    HStack(spacing: 4) {
                        Circle().fill(BrowserColor.forBrowser(b))
                            .frame(width: 6, height: 6)
                        Text(b).font(.caption2)
                            .foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
            }
        }
    }

    private func monthTicks(_ days: [String]) -> [String] {
        var seen = Set<String>()
        var ticks: [String] = []
        for d in days {
            let m = String(d.prefix(7))
            if !seen.contains(m) { seen.insert(m); ticks.append(m) }
        }
        return ticks
    }
}

/// 7×24 visit-density heatmap — GitHub-style intensity grid.
struct ActivityHeatmap: View {
    let cells: [Int64]  // [dow*24 + hour]

    private let dayNames = ["S", "M", "T", "W", "T", "F", "S"]
    private let dayFull = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        let mx = max(1, cells.max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text("").frame(width: 14)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 6 == 0 ? "\(h)" : "")
                        .font(.system(size: 6))
                        .foregroundStyle(BrowserTheme.secondaryInk)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 2) {
                    Text(dayNames[d])
                        .font(.system(size: 7))
                        .foregroundStyle(BrowserTheme.secondaryInk)
                        .frame(width: 14, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let n = cells[d * 24 + h]
                        let v = Double(n) / Double(mx)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(BrowserTheme.mintInk
                                .opacity(v < 0.02 ? 0.08 : 0.12 + v * 0.88))
                            .frame(maxWidth: .infinity, minHeight: 14)
                            .help("\(dayFull[d]) \(h):00–\(h + 1):00 — "
                                  + "\(n.formatted()) visits")
                    }
                }
            }
        }
    }
}

/// Labeled sparkline card — used for focus trend and archive growth.
struct TrendLine: View {
    enum Kind { case seconds, count }
    let title: String
    let points: [Double]
    var labels: (first: String, last: String) = ("", "")
    var pointLabels: [String] = []   // per-point axis labels for hover
    var color: Color = BrowserTheme.mintInk
    var kind: Kind = .seconds
    @State private var hover: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold))
                    .foregroundStyle(BrowserTheme.secondaryInk)
                Spacer()
                if let i = hover, points.indices.contains(i) {
                    Text(hoverLabel(i))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(BrowserTheme.secondaryInk)
                }
                Text(shown).font(.callout.monospacedDigit().bold())
                    .foregroundStyle(hover == nil
                                     ? BrowserTheme.ink : BrowserTheme.mintInk)
            }
            Sparkline(values: points, color: color,
                      hoverIndex: $hover).frame(height: 56)
            HStack {
                Text(labels.first).font(.system(size: 8))
                Spacer()
                Text(labels.last).font(.system(size: 8))
            }
            .foregroundStyle(BrowserTheme.secondaryInk.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shown: String { format(points[hover ?? points.count - 1]) }
    private func hoverLabel(_ i: Int) -> String {
        pointLabels.indices.contains(i) ? pointLabels[i] : ""
    }
    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        switch kind {
        case .seconds:
            return v >= 3600 ? String(format: "%.1fh", v / 3600)
                 : v >= 60 ? String(format: "%.0fm", v / 60)
                 : String(format: "%.0fs", v)
        case .count:
            return Int64(v).formatted()
        }
    }
}
