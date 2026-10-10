import AppKit
import BrowserCore
import SwiftUI
import SaaSMakerUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedRow: String?
    @State private var tagTarget: AppModel.HistoryRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(BrowserTheme.mintInk.opacity(0.18))
            if model.historyRows.isEmpty { emptyState } else { historyList }
        }
        .sheet(item: $tagTarget) { row in
            HistoryTagSheet(row: row).environmentObject(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                DaddyArtwork(brand: true).frame(width: 34, height: 34)
                TextField("Search URLs and titles…", text: $model.searchTerm)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(BrowserTheme.mintInk.opacity(0.45), lineWidth: 1))
                    .accessibilityLabel("Search archived history")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filterControls }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { browserMenu; sourceMenu; rangeMenu }
                    HStack(spacing: 8) { categoryMenu; tagMenu; clearFilters }
                }
            }
            HStack(spacing: 8) {
                Text(resultSummary)
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                if model.historyActiveFilterCount > 0 {
                    SMStatusPill("\(model.historyActiveFilterCount) active \(model.historyActiveFilterCount == 1 ? "filter" : "filters")",
                                 tone: .brand)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
    }

    @ViewBuilder private var filterControls: some View {
        browserMenu
        sourceMenu
        rangeMenu
        categoryMenu
        tagMenu
        clearFilters
    }

    private var browserMenu: some View {
        filterMenu(label: model.browserFilter == "all" ? "all browsers" : model.browserFilter,
                   icon: "globe") {
            Button("all browsers") { model.browserFilter = "all" }
            ForEach(model.browsers, id: \.self) { browser in
                Button(browser) { model.browserFilter = browser }
            }
        }
    }

    private var sourceMenu: some View {
        filterMenu(label: model.historySourceFilter == "all" ? "all profiles" : model.historySourceFilter,
                   icon: "person.crop.rectangle.stack") {
            Button("all profiles") { model.historySourceFilter = "all" }
            ForEach(model.historySources, id: \.self) { source in
                Button(source) { model.historySourceFilter = source }
            }
        }
    }

    private var rangeMenu: some View {
        filterMenu(label: model.historyDaysFilter == 0 ? "all time" : "last \(model.historyDaysFilter) days",
                   icon: "calendar") {
            ForEach([(0, "all time"), (1, "last 24 hours"), (7, "last 7 days"),
                     (30, "last 30 days"), (90, "last 90 days")], id: \.0) { days, label in
                Button(label) { model.historyDaysFilter = days }
            }
        }
    }

    private var categoryMenu: some View {
        filterMenu(label: model.historyCategoryFilter == "all" ? "all categories" : model.historyCategoryFilter,
                   icon: "tag") {
            Button("all categories") { model.historyCategoryFilter = "all" }
            ForEach(model.historyCategories, id: \.self) { category in
                Button(category) { model.historyCategoryFilter = category }
            }
        }
    }

    private var tagMenu: some View {
        filterMenu(label: tagFilterLabel, icon: "tag.square") {
            Button("any tag state") { model.historyTagFilter = .all }
            Button("tagged") { model.historyTagFilter = .tagged }
            Button("untagged") { model.historyTagFilter = .untagged }
            Button("your overrides") { model.historyTagFilter = .manual }
        }
    }

    @ViewBuilder private var clearFilters: some View {
        if model.historyActiveFilterCount > 0 {
            Button("Clear") { model.clearHistoryFilters() }.textCase(.lowercase)
                .buttonStyle(DaddyButtonStyle())
                .help("Clear all history filters; search text stays in place")
        }
    }

    private func filterMenu<Content: View>(label: String, icon: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Label(label, systemImage: icon)
                .lineLimit(1).padding(.horizontal, 9).padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(BrowserTheme.mintInk.opacity(0.4), lineWidth: 1))
    }

    private var historyList: some View {
        List(model.historyRows) { row in
            VStack(alignment: .leading, spacing: 0) {
                Button { expandedRow = expandedRow == row.id ? nil : row.id } label: {
                    summary(row)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.title.isEmpty ? row.url : row.title), \(row.source)")
                .accessibilityValue(expandedRow == row.id ? "Expanded" : "Collapsed")
                .accessibilityHint("Show visit evidence and tagging options")
                if expandedRow == row.id { expandedDetail(row) }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.black)
            .contextMenu { rowActions(row) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    private func summary(_ row: AppModel.HistoryRow) -> some View {
        HStack(spacing: 12) {
            Text(row.time?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .font(.caption.monospaced()).foregroundStyle(BrowserTheme.secondaryInk)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.browser).font(.caption.weight(.medium)).foregroundStyle(BrowserTheme.cyan)
                Text(row.profile).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.isEmpty ? row.url : row.title)
                    .foregroundStyle(BrowserTheme.ink).lineLimit(1).truncationMode(.tail)
                Text(row.url).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let category = row.category {
                Text(category).font(.caption2.weight(.semibold))
                    .foregroundStyle(row.tagSource == "user" ? Color.black : BrowserTheme.mintInk)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(row.tagSource == "user" ? BrowserTheme.mintInk
                                : BrowserTheme.mintInk.opacity(0.12), in: Capsule())
            } else {
                Text("untagged").font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: expandedRow == row.id ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.bold)).foregroundStyle(BrowserTheme.mintInk)
                .frame(width: 16)
        }
        .contentShape(Rectangle())
    }

    private func expandedDetail(_ row: AppModel.HistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(BrowserTheme.divider)
            detailLine("Source", row.source)
            detailLine("Visited", row.time?.formatted(date: .complete, time: .standard) ?? "Unavailable")
            detailLine("Address", row.url)
            detailLine("Page tag", scopedTag(row.pageCategory, row.pageTagSource))
            detailLine("Domain", scopedTag(row.domainCategory, row.domainTagSource))
            HStack(spacing: 8) {
                Button { tagTarget = row } label: { Label("Retag", systemImage: "tag").textCase(.lowercase) }
                    .buttonStyle(DaddyButtonStyle(prominent: true))
                Button { copy(row.url) } label: { Label("Copy URL", systemImage: "doc.on.doc").textCase(.lowercase) }
                    .buttonStyle(DaddyButtonStyle())
                Button { open(row.url) } label: { Label("Open", systemImage: "arrow.up.right.square").textCase(.lowercase) }
                    .buttonStyle(DaddyButtonStyle())
                Spacer()
                Text("Local archive evidence")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 252).padding(.top, 8).padding(.bottom, 6)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.lowercased()).font(.caption2.weight(.semibold))
                .tracking(0.7).foregroundStyle(BrowserTheme.secondaryInk)
                .frame(width: 58, alignment: .leading)
            Text(value).font(.caption).foregroundStyle(BrowserTheme.ink)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func rowActions(_ row: AppModel.HistoryRow) -> some View {
        Button("Expand details") { expandedRow = row.id }.textCase(.lowercase)
        Button("Retag…") { tagTarget = row }.textCase(.lowercase)
        Divider()
        Button("Copy URL") { copy(row.url) }.textCase(.lowercase)
        Button("Open URL") { open(row.url) }.textCase(.lowercase)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            DaddyArtwork().frame(width: 72, height: 72)
            SMDisplay(model.report == nil || model.report?.totalVisits == 0
                      ? "Nothing archived yet" : "No matches", size: 22)
            Text(model.report == nil || model.report?.totalVisits == 0
                 ? "Connect a browser folder in Permissions, then sync history."
                 : "Search and filters combine. Clear them to return to the full archive.")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            if model.historyActiveFilterCount > 0 {
                Button("Clear filters") { model.clearHistoryFilters() }.textCase(.lowercase)
                    .buttonStyle(DaddyButtonStyle(prominent: true))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultSummary: String {
        model.historyRows.count == 500 ? "Showing the latest 500 matches"
            : "\(model.historyRows.count.formatted()) \(model.historyRows.count == 1 ? "visit" : "visits")"
    }

    private var tagFilterLabel: String {
        switch model.historyTagFilter {
        case .all: "any tag state"
        case .tagged: "tagged"
        case .untagged: "untagged"
        case .manual: "your overrides"
        }
    }

    private func scopedTag(_ category: String?, _ source: String?) -> String {
        guard let category else { return "Untagged" }
        return "\(category) · \(source == "user" ? "your override" : "classifier.dev")"
    }

    private func copy(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func open(_ value: String) {
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }
}

private struct HistoryTagSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let row: AppModel.HistoryRow
    @State private var scope: AppModel.HistoryTagScope
    @State private var category: String

    init(row: AppModel.HistoryRow) {
        self.row = row
        let initialScope: AppModel.HistoryTagScope = row.tagScope == "page" ? .page : .domain
        _scope = State(initialValue: initialScope)
        let labels = initialScope == .page ? Classifier.pageLabels : Classifier.domainLabels
        let current = row.category ?? ""
        _category = State(initialValue: labels.contains(current) ? current : labels[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                DaddyArtwork(brand: true).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    SMSectionHeader("Retag this visit", size: 22)
                    Text(row.host).font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
                Spacer()
            }
            Text("Choose how broadly the local override applies. Browser history is never changed, and saving here makes no network request.")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            VStack(alignment: .leading, spacing: 8) {
                Text("SCOPE").textCase(.lowercase).font(.caption2.weight(.semibold)).tracking(0.8)
                    .foregroundStyle(BrowserTheme.secondaryInk)
                Picker("Scope", selection: $scope) {
                    ForEach(AppModel.HistoryTagScope.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }.pickerStyle(.segmented)
                Text(scopeExplanation).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("CATEGORY").textCase(.lowercase).font(.caption2.weight(.semibold)).tracking(0.8)
                    .foregroundStyle(BrowserTheme.secondaryInk)
                Picker("Category", selection: $category) {
                    ForEach(labels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
            }
            if let existing = row.category {
                Text("Current effective tag: \(existing) · \(row.tagSource == "user" ? "your override" : "classifier.dev")")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
            }
            if let error = model.historyActionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(BrowserTheme.coral)
            }
            Divider().overlay(BrowserTheme.divider)
            HStack {
                Button("Clear this scope") {
                    if model.clearHistoryTag(row, scope: scope) { dismiss() }
                }.textCase(.lowercase).buttonStyle(DaddyButtonStyle())
                    .help("Remove only the derived tag at this scope; visits remain archived")
                Spacer()
                Button("Cancel") { dismiss() }.textCase(.lowercase).buttonStyle(DaddyButtonStyle())
                Button("Save local tag") {
                    if model.setHistoryTag(row, scope: scope, category: category) { dismiss() }
                }.textCase(.lowercase).buttonStyle(DaddyButtonStyle(prominent: true))
            }
            Text(model.classifyOptin
                 ? "Optional external classification is enabled separately. It only runs when you choose Tag in Permissions."
                 : "Optional external classification is off. You can manage its explicit consent in Permissions.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(24).frame(width: 560)
        .background(Color.black)
        .onAppear { model.historyActionError = nil }
        .onChange(of: scope) { _, _ in
            if !labels.contains(category) { category = labels[0] }
        }
    }

    private var labels: [String] {
        scope == .page ? Classifier.pageLabels : Classifier.domainLabels
    }

    private var scopeExplanation: String {
        switch scope {
        case .page: "Only this exact URL. A page tag takes precedence in the timeline."
        case .domain: "Every archived visit to \(row.host)."
        case .rollup: "Every seen subdomain under \(Domain.rollup(row.host))."
        }
    }
}
