import SwiftUI
import SaaSMakerUI
import BrowserCore

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    /// "% of total" note for ranked rows.
    private func pct(_ n: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        let p = 100.0 * Double(n) / Double(total)
        return p < 0.5 ? "<1%" : String(format: "%.0f%%", p)
    }

    var body: some View {
        ScrollView {
            if let r = model.report, r.totalVisits > 0 {
                VStack(spacing: 16) {
                    FilterBar()
                    verdict(r)
                    changedLately(r)
                    spotCheck(r)
                    timeline(r)
                    trends(r)
                    categories(r)
                    topics(r)
                    sites(r)
                    deepRead(r)
                    heatmap(r)
                    profiles(r)
                    days(r)
                    dayEdges(r)
                    habits(r)
                    shared(r)
                    pace(r)
                    sessions(r)
                    searches(r)
                }
                .padding(28)
                .frame(maxWidth: 1_080)
                .frame(maxWidth: .infinity)
            } else {
                emptyState
            }
        }
    }

    // MARK: - headline

    private func verdict(_ r: ReportEngine.Report) -> some View {
        HStack(alignment: .top, spacing: 18) {
            DaddyArtwork(brand: true).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 7) {
                SMSectionHeader("\(r.totalVisits.formatted()) visits archived", size: 32)
                    .accessibilityAddTraits(.isHeader)
                Text("\(r.uniqueURLs.formatted()) unique URLs across "
                     + "\(r.uniqueDomains.formatted()) domains")
                    .foregroundStyle(BrowserTheme.secondaryInk)
                Label(rangeText(r), systemImage: "archivebox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrowserTheme.secondaryInk)
            }
            Spacer()
        }
        .padding(24)
        .background(BrowserTheme.mint)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func rangeText(_ r: ReportEngine.Report) -> String {
        let f = r.sources.map(\.first).min() ?? "—"
        let l = r.sources.map(\.last).max() ?? "—"
        return "\(f) → \(l) · survives browser pruning"
    }

    // MARK: - timeline

    private func timeline(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "TIMELINE",
                    subtitle: "Visits per bucket, stacked by browser") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("granularity", selection: $model.granularity) {
                    Text("Day").textCase(.lowercase).tag(0); Text("Week").textCase(.lowercase).tag(1); Text("Month").textCase(.lowercase).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                DailyStackedBars(
                    series: model.granularity == 2 ? r.monthlySeries
                          : model.granularity == 1 ? r.weeklySeries
                          : r.dailySeries,
                    height: model.granularity == 0 ? 140 : 100)
            }
        }
    }

    // MARK: - changed lately

    private func changedLately(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "CHANGED LATELY",
                    subtitle: "\(r.curPeriodLabel) vs \(r.prevPeriodLabel)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(r.changedLately.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(c.pct >= 0 ? "+" : "")\(Int(c.pct))%")
                            .font(.callout.monospacedDigit().bold())
                            .foregroundStyle(c.pct >= 0 ? BrowserTheme.coral
                                                        : BrowserTheme.mintInk)
                            .frame(width: 64, alignment: .trailing)
                        Text(c.host).foregroundStyle(BrowserTheme.ink)
                        Spacer()
                        Text("\(c.prev.formatted()) → \(c.cur.formatted()) visits")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            model.checkHost = c.host
                            model.runSiteCheck()
                        } label: {
                            Image(systemName: "scope")
                        }.buttonStyle(.plain)
                            .foregroundStyle(BrowserTheme.mintInk)
                            .help("Open in Spot Check")
                    }
                    .contextMenu { tagMenu(c.host) }
                }
                Text("green = down, coral = up — clicks send a site to Spot Check")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - spot check

    private func spotCheck(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "SPOT CHECK",
                    subtitle: "Did it change? — \(r.curPeriodLabel) vs \(r.prevPeriodLabel)") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(r.topDomains.prefix(30), id: \.label) { d in
                            Button(d.label) {
                                model.checkHost = d.label
                                model.runSiteCheck()
                            }
                        }
                    } label: {
                        Label(model.checkHost, systemImage: "scope")
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(BrowserTheme.mintInk.opacity(0.4), lineWidth: 1))
                    .onAppear { model.runSiteCheck() }
                    Spacer()
                }
                if let c = model.siteCheck {
                    verdictLine(c)
                    Sparkline(values: c.daily.map { Double($0.value) },
                              color: BrowserTheme.mintInk).frame(height: 34)
                    Text("daily visits, last 60 days — \(c.daily.first?.label ?? "") → \(c.daily.last?.label ?? "")")
                        .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
        }
    }

    /// Right-click "Tag as…" for any domain row — writes a user override.
    @ViewBuilder private func tagMenu(_ host: String) -> some View {
        Menu("Tag as…") {
            ForEach(Classifier.domainLabels, id: \.self) { l in
                Button(l) { model.overrideDomain(host, l) }
            }
        }
    }

    /// Same for eTLD+1 rollup rows (SITES band).
    @ViewBuilder private func rollupTagMenu(_ rollup: String) -> some View {
        Menu("Tag as…") {
            ForEach(Classifier.domainLabels, id: \.self) { l in
                Button(l) { model.overrideRollup(rollup, l) }
            }
        }
    }

    private func verdictLine(_ c: ReportEngine.SiteCheck) -> some View {
        let up = c.deltaPct >= 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(up ? "+" : "")\(String(format: "%.0f", c.deltaPct))%")
                    .font(.title.bold())
                    .foregroundStyle(up ? BrowserTheme.coral : BrowserTheme.mintInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.thisMonth.formatted()) visits so far this month")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(BrowserTheme.ink)
                    Text("vs \(c.lastMonthSameDays.formatted()) by this point last month")
                        .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
            Text(focusVerdict(c)).font(.caption)
                .foregroundStyle(BrowserTheme.secondaryInk)
        }
    }

    private func focusVerdict(_ c: ReportEngine.SiteCheck) -> String {
        if c.focusThisWeek == 0 && c.focusPrevWeek == 0 {
            return "no focus data yet — visits count opens, not watch time"
        }
        let cur = fmtDur(c.focusThisWeek), prev = fmtDur(c.focusPrevWeek)
        return "focused time: \(cur) this week vs \(prev) last week"
    }

    // MARK: - categories

    private func categories(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "CATEGORIES",
                    subtitle: "classifier.dev batch grouping — what browsing is actually for") {
            VStack(alignment: .leading, spacing: 10) {
                let mx = max(1, r.categories.map(\.value).max() ?? 1)
                ForEach(Array(r.categories.prefix(12).enumerated()),
                        id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(c.value.formatted())
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(catColor(c.label))
                                .frame(minWidth: 62, alignment: .trailing)
                            Text(c.label).foregroundStyle(BrowserTheme.ink)
                            Text(String(format: "%.0f%%",
                                        100.0 * Double(c.value)
                                        / Double(r.totalVisits)))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(topIn(r, c.label)).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        ShareBar(fraction: Double(c.value) / Double(mx),
                                 color: catColor(c.label)).frame(height: 4)
                    }
                }
                if !r.categoryTrends.isEmpty {
                    Divider().overlay(BrowserTheme.divider)
                    Text("monthly").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.categoryTrends.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 14) {
                            Text(t.category).font(.callout)
                                .foregroundStyle(catColor(t.category))
                                .frame(width: 130, alignment: .leading)
                            Sparkline(values: t.monthly.map { Double($0.value) },
                                      color: catColor(t.category))
                                .frame(height: 26)
                            Text(t.monthly.last.map { $0.value.formatted() } ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(BrowserTheme.secondaryInk)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func topIn(_ r: ReportEngine.Report, _ cat: String) -> String {
        r.categoryTopDomains.first { $0.category == cat }?.domains
            .map(\.label).joined(separator: ", ") ?? ""
    }

    private func catColor(_ c: String) -> Color {
        switch c {
        case "development": BrowserTheme.mintInk
        case "ai-tools": BrowserTheme.cyan
        case "social-media": BrowserTheme.blue
        case "video", "entertainment", "music", "gaming": BrowserTheme.coral
        case "finance", "shopping": BrowserTheme.amber
        case "search", "documentation", "education": BrowserTheme.secondaryInk
        default: BrowserTheme.secondaryInk.opacity(0.7)
        }
    }

    // MARK: - topics

    private func topics(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "TOPICS",
                    subtitle: "Page-level classification — what the content actually is") {
            VStack(alignment: .leading, spacing: 10) {
                let mx = max(1, r.topics.map(\.value).max() ?? 1)
                ForEach(Array(r.topics.prefix(12).enumerated()),
                        id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(t.value.formatted())
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(catColor(t.label))
                                .frame(minWidth: 62, alignment: .trailing)
                            Text(t.label).foregroundStyle(BrowserTheme.ink)
                            Text(pct(t.value, of: r.totalVisits))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(topTopic(r, t.label)).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        ShareBar(fraction: Double(t.value) / Double(mx),
                                 color: catColor(t.label)).frame(height: 4)
                    }
                }
                if !r.topicTrends.isEmpty {
                    Divider().overlay(BrowserTheme.divider)
                    Text("monthly").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.topicTrends.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 14) {
                            Text(t.topic).font(.callout)
                                .foregroundStyle(catColor(t.topic))
                                .frame(width: 130, alignment: .leading)
                            Sparkline(values: t.monthly.map { Double($0.value) },
                                      color: catColor(t.topic))
                                .frame(height: 26)
                            Text(t.monthly.last.map { $0.value.formatted() } ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(BrowserTheme.secondaryInk)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func topTopic(_ r: ReportEngine.Report, _ t: String) -> String {
        r.topicPages.first { $0.topic == t }?.pages
            .map { p in
                URL(string: p.label)?.host ?? p.label
            }.joined(separator: ", ") ?? ""
    }

    // MARK: - deep read

    private func deepRead(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "DEEP READ",
                    subtitle: "Focused minutes per visit — the sites you actually read vs. quick-hit") {
            VStack(alignment: .leading, spacing: 8) {
                if r.focusDaily.count < 3 {
                    Text("Accumulating — needs ~3 days of focus data "
                         + "(\(r.focusDaily.count) so far) before "
                         + "minutes-per-visit means anything.")
                        .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                } else if r.deepRead.isEmpty {
                    Text("Needs both history and accumulated focus data.")
                        .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
                ForEach(Array(r.deepRead.enumerated()), id: \.offset) { _, d in
                    RankRow(value: d.extra.replacingOccurrences(
                                of: " min active / visit", with: "m"),
                            label: d.label)
                }
            }
        }
    }

    // MARK: - day edges

    private func dayEdges(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "DAY EDGES",
                    subtitle: "What starts and ends a browsing day · median \(r.medianDayStart)–\(r.medianDayEnd)") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("opens with").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.dayStarts.enumerated()), id: \.offset) { _, d in
                        RankRow(value: "\(d.value)×", label: d.label,
                                note: pct(d.value, of: activeDays(r)))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("closes with").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.dayEnds.enumerated()), id: \.offset) { _, d in
                        RankRow(value: "\(d.value)×", label: d.label,
                                note: pct(d.value, of: activeDays(r)))
                    }
                }
            }
        }
    }

    // MARK: - habits

    private func habits(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "HABITS",
                    subtitle: "Sites on ≥80% of active days · how fast you return") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("daily fixtures").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.habitual.enumerated()), id: \.offset) { _, h in
                        RankRow(value: "\(h.value)d", label: h.label,
                                note: h.extra)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("return speed").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.returnGaps.enumerated()), id: \.offset) { _, g in
                        RankRow(value: g.extra
                                    .replacingOccurrences(of: " median gap",
                                                          with: ""),
                                label: g.label)
                    }
                }
            }
        }
    }

    // MARK: - pace

    private func pace(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "PACE",
                    subtitle: "Attention fragmentation — from live focus data") {
            if r.focusDaily.count < 3 {
                Text("Accumulating — \(r.focusDaily.count) day(s) of focus "
                     + "data; fragmentation stats need ~a week.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            } else {
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "%.0f", r.switchesPerFocusHour))
                        .font(.title2.bold()).foregroundStyle(BrowserTheme.amber)
                    Text("app/site switches per focused hour")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(fmtDur(r.medianSpanSeconds))
                        .font(.title2.bold()).foregroundStyle(BrowserTheme.mintInk)
                    Text("median focused span")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }
        }
    }

    // MARK: - trends

    private func trends(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "TRENDS",
                    subtitle: "Focus per day · exploration rate · top-site momentum") {
            HStack(alignment: .top, spacing: 20) {
                TrendLine(
                    title: "Focused time / day",
                    points: r.focusDaily.map(\.activeSeconds),
                    labels: (r.focusDaily.first?.date ?? "",
                             r.focusDaily.last?.date ?? ""),
                    pointLabels: r.focusDaily.map(\.date))
                TrendLine(
                    title: "New domains / month",
                    points: r.newDomainsPerWeek.map { Double($0.value) },
                    labels: (r.newDomainsPerWeek.first?.label ?? "",
                             r.newDomainsPerWeek.last?.label ?? ""),
                    pointLabels: r.newDomainsPerWeek.map(\.label),
                    color: BrowserTheme.amber, kind: .count)
            }
            HStack(alignment: .top, spacing: 20) {
                TrendLine(
                    title: "Novelty — % visits to new domains / week",
                    points: r.noveltyWeekly.map { Double($0.value) },
                    labels: (r.noveltyWeekly.first?.label ?? "",
                             r.noveltyWeekly.last?.label ?? ""),
                    pointLabels: r.noveltyWeekly.map(\.label),
                    color: BrowserTheme.blue, kind: .count)
                TrendLine(
                    title: "Night-owl share / month (23–05)",
                    points: r.nightShare.map { Double($0.value) },
                    labels: (r.nightShare.first?.label ?? "",
                             r.nightShare.last?.label ?? ""),
                    pointLabels: r.nightShare.map(\.label),
                    color: BrowserTheme.coral, kind: .count)
            }
            if !r.domainTrends.isEmpty {
                Divider().overlay(BrowserTheme.divider)
                ForEach(Array(r.domainTrends.enumerated()), id: \.offset) { _, t in
                    HStack(spacing: 14) {
                        Text(t.domain).font(.callout)
                            .foregroundStyle(BrowserTheme.ink)
                            .frame(width: 160, alignment: .leading)
                        Sparkline(values: t.monthly.map { Double($0.value) },
                                  color: BrowserTheme.mintInk)
                            .frame(height: 26)
                        Text(t.monthly.last.map { "\($0.value.formatted())" } ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(BrowserTheme.secondaryInk)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - heatmap

    private func heatmap(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "HEATMAP",
                    subtitle: "Visit density — weekday × hour (local time)") {
            ActivityHeatmap(cells: r.heatmap)
        }
    }

    // MARK: - sites

    private func sites(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "SITES",
                    subtitle: "Where visits concentrate — registrable-domain rollup") {
            VStack(alignment: .leading, spacing: 8) {
                let mx = max(1, r.topSites.map(\.value).max() ?? 1)
                ForEach(Array(r.topSites.prefix(15).enumerated()),
                        id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 3) {
                        RankRow(value: s.value.formatted(), label: s.label,
                                note: pct(s.value, of: r.totalVisits)
                                    + (r.userRollupTags.contains(s.label)
                                       ? " · your tag" : ""))
                            .contextMenu { rollupTagMenu(s.label) }
                        ShareBar(fraction: Double(s.value) / Double(mx))
                            .frame(height: 3)
                    }
                }
            }
        }
    }

    // MARK: - profiles

    private func profiles(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "PROFILES",
                    subtitle: "Each browser/profile has a job — and a rhythm") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(r.personalities, id: \.label) { p in
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label).font(.callout.weight(.medium))
                                .foregroundStyle(BrowserTheme.ink)
                            Text(p.extra).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 200, alignment: .leading)
                        if let ph = r.profileHours.first(
                            where: { $0.source == p.label }) {
                            let mx = max(1, ph.hours.max() ?? 1)
                            Sparkline(values: ph.hours.map {
                                Double($0) / Double(mx) },
                                      color: BrowserTheme.cyan)
                                .frame(height: 26)
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(p.value.formatted())
                                .font(.callout.monospacedDigit().bold())
                                .foregroundStyle(BrowserTheme.mintInk)
                            Text(pct(p.value, of: r.totalVisits))
                                .font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 70, alignment: .trailing)
                    }
                }
                Divider().overlay(BrowserTheme.divider)
                ForEach(r.sources, id: \.name) { s in
                    RankRow(value: s.visits.formatted(), label: s.name,
                            note: "\(pct(s.visits, of: r.totalVisits)) · \(s.first) → \(s.last)")
                }
            }
        }
    }

    // MARK: - days

    private func days(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "DAYS",
                    subtitle: "Day-of-week by source · busiest days · streaks") {
            VStack(alignment: .leading, spacing: 16) {
                // dow × source matrix
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Text("").frame(width: 140, alignment: .leading)
                        ForEach(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"],
                                id: \.self) { d in
                            Text(d).font(.caption2.weight(.semibold))
                                .foregroundStyle(BrowserTheme.secondaryInk)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(Array(r.dowBySource.enumerated()), id: \.offset) { _, s in
                        let mx = max(1, s.days.max() ?? 1)
                        HStack(spacing: 0) {
                            Text(s.source).font(.caption)
                                .foregroundStyle(BrowserTheme.ink)
                                .frame(width: 140, alignment: .leading)
                            ForEach(0..<7, id: \.self) { d in
                                let v = Double(s.days[d]) / Double(mx)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(BrowserTheme.mintInk
                                        .opacity(v < 0.02 ? 0.08
                                                 : 0.15 + v * 0.85))
                                    .frame(height: 14)
                                    .frame(maxWidth: .infinity)
                                    .help("\(s.source) \(d): \(s.days[d])")
                            }
                        }
                    }
                }
                Divider().overlay(BrowserTheme.divider)
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("busiest days").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(r.busiestDays.prefix(8).enumerated()),
                                id: \.offset) { _, d in
                            RankRow(value: d.value.formatted(), label: d.label,
                                    note: pct(d.value, of: r.totalVisits))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("consistency").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        RankRow(value: "\(r.longestStreak)d",
                                label: "longest daily streak")
                        RankRow(value: r.medianVisitsPerDay.formatted(),
                                label: "median visits/day")
                        RankRow(value: "\(r.longestGapDays)d",
                                label: "longest gap (no visits)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - shared

    private func shared(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "SHARED",
                    subtitle: "Domains alive in more than one browser/profile") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(r.sharedDomains.enumerated()), id: \.offset) { _, s in
                    RankRow(value: s.visits.formatted(), label: s.domain,
                            note: "\(s.sources) · \(pct(s.visits, of: r.totalVisits))")
                }
            }
        }
    }

    // MARK: - sessions

    private func sessions(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "SESSIONS",
                    subtitle: "30-minute-gap sessions and the deepest rabbit holes") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(r.sessionSummary.enumerated()), id: \.offset) { _, s in
                    RankRow(value: s.value.formatted(), label: s.label,
                            note: s.extra)
                }
                if !r.rabbitHoles.isEmpty {
                    Divider().overlay(BrowserTheme.divider)
                    Text("deepest rabbit holes").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(r.rabbitHoles.enumerated()), id: \.offset) { _, h in
                        RankRow(value: "\(h.domains) dom",
                                label: h.start.formatted(
                                    date: .abbreviated, time: .shortened),
                                note: "\(h.visits) visits · \(fmtDur(h.spanSeconds))")
                    }
                }
            }
        }
    }

    // MARK: - searches

    private func searches(_ r: ReportEngine.Report) -> some View {
        BrowserBand(label: "SEARCHES",
                    subtitle: "Chromium omnibox queries — browsers differ in what they record") {
            VStack(alignment: .leading, spacing: 8) {
                if r.searches.isEmpty {
                    Text("No search terms captured yet.")
                        .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
                let searchTotal = r.searches.reduce(0) { $0 + $1.value }
                ForEach(Array(r.searches.enumerated()), id: \.offset) { _, s in
                    RankRow(value: s.value.formatted(), label: s.label,
                            note: pct(s.value, of: searchTotal))
                }
            }
        }
    }

    private func activeDays(_ r: ReportEngine.Report) -> Int64 {
        Int64(max(1, Set(r.dailySeries.map(\.date)).count))
    }

    // MARK: - empty

    private var emptyState: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                Circle().fill(BrowserTheme.mint).frame(width: 92, height: 92)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(BrowserTheme.mintInk)
            }
            VStack(spacing: 10) {
                SMDisplay("No history archived yet", size: 32)
                Text("BrowserDaddy reads browser history into a permanent local archive. "
                     + "Connect a browser folder in Permissions, then sync.")
                    .foregroundStyle(BrowserTheme.secondaryInk)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            Button(model.extracting ? "Syncing…" : "Sync History",
                   action: model.runExtract)
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.extracting)
            if let last = model.extractLog.last {
                Text(last)
                    .font(.caption)
                    .foregroundStyle(last.hasPrefix("✗")
                                     ? BrowserTheme.coral
                                     : BrowserTheme.secondaryInk)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            Spacer()
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
