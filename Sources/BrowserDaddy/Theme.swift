import SwiftUI
import SaaSMakerUI

/// Daddy series theme — same palette as StorageDaddy/PerformanceDaddy.
enum BrowserTheme {
    static let palette: SMPalette = {
        var palette = SMPalette.ink.dark.brand(DaddyPalette.mint, foreground: .black)
        palette.background = DaddyPalette.canvas
        palette.surface = DaddyPalette.canvas
        palette.card = DaddyPalette.canvas
        palette.foreground = DaddyPalette.ink
        palette.mutedForeground = DaddyPalette.secondaryInk
        palette.hairline = DaddyPalette.secondaryInk.opacity(0.18)
        palette.border = palette.hairline
        palette.input = palette.hairline
        palette.accent = DaddyPalette.mint.opacity(0.11)
        palette.success = DaddyPalette.mint
        palette.destructive = DaddyPalette.coral
        palette.warning = DaddyPalette.amber
        palette.radius = 10
        palette.displayFont = palette.sansFont
        palette.displayWeight = 600
        palette.displayTracking = -0.025
        return palette
    }()

    static let fog = DaddyPalette.canvas
    static let surface = DaddyPalette.canvas
    static let ink = DaddyPalette.ink
    static let secondaryInk = DaddyPalette.secondaryInk
    static let coral = DaddyPalette.coral
    static let coralWash = coral.opacity(0.12)
    static let mintInk = DaddyPalette.mint
    static let mint = mintInk.opacity(0.18)
    static let action = mintInk
    static let blue = DaddyPalette.blue
    static let cyan = DaddyPalette.cyan
    static let amber = DaddyPalette.amber
    static let divider = secondaryInk.opacity(0.18)
}

/// One quiet page introduction across the app's workspaces.
struct BrowserPageHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        SMWorkspaceHeader(title, subtitle: subtitle) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BrowserTheme.mintInk)
                .frame(width: 42, height: 42)
                .background(BrowserTheme.palette.brandSoft, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
        }
        .padding(.bottom, 6)
    }
}

/// Labeled card section, same rhythm as PerformanceDaddy's TriageBand.
struct BrowserBand<Content: View>: View {
    let label: String
    let subtitle: String
    @ViewBuilder let content: Content
    @State private var collapsed = false
    private var storeKey: String { "band-collapsed-\(label)" }

    var body: some View {
        SMCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                bandHeading
                if !collapsed {
                    Divider().overlay(BrowserTheme.divider)
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            collapsed = UserDefaults.standard.bool(forKey: storeKey)
        }
    }

    private var bandHeading: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            UserDefaults.standard.set(collapsed, forKey: storeKey)
        } label: {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label.localizedLowercase)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BrowserTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BrowserTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BrowserTheme.secondaryInk)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(label)")
    }
}

/// Ranked row: mono value, label, trailing note — the list atom.
struct RankRow: View {
    let value: String
    let label: String
    var note = ""
    var color: Color = BrowserTheme.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(BrowserTheme.mintInk)
                .frame(minWidth: 62, alignment: .trailing)
            Text(label)
                .foregroundStyle(color)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Area+stroke sparkline, ported from PerformanceDaddy.
struct Sparkline: View {
    let values: [Double]
    var color: Color = BrowserTheme.mintInk
    /// Optional — supply a binding to enable hover tracking + marker.
    var hoverIndex: Binding<Int?>? = nil

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(values.max() ?? 1, 1)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: values.count <= 1 ? 0
                        : geometry.size.width * CGFloat(index)
                          / CGFloat(values.count - 1),
                    y: geometry.size.height
                        * (1 - CGFloat(value / maximum) * 0.88))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                    path.addLine(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    if let last = points.last {
                        path.addLine(to: CGPoint(x: last.x,
                                                 y: geometry.size.height))
                    }
                    path.closeSubpath()
                }
                .fill(color.opacity(0.12))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(
                    lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let i = hoverIndex?.wrappedValue,
                   points.indices.contains(i) {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .position(points[i])
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard let hoverIndex, values.count > 1 else { return }
                switch phase {
                case .active(let p):
                    let frac = p.x / max(1, geometry.size.width)
                    hoverIndex.wrappedValue = max(0, min(values.count - 1,
                        Int(frac * CGFloat(values.count - 1) + 0.5)))
                case .ended:
                    hoverIndex.wrappedValue = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
    }
}

/// Shared filter controls — source + range, daddy-styled bordered menus.
struct FilterBar: View {
    @EnvironmentObject var model: AppModel
    /// Focus data has no profile dimension — hide source on Attention.
    var showSource = true

    var body: some View {
        HStack(spacing: 10) {
            if showSource { sourceMenu }
            rangeMenu
            if model.filterSource != "all" || model.filterDays != 0 {
                Button("Clear filters") {
                    model.filterSource = "all"
                    model.filterDays = 0
                }.textCase(.lowercase)
            }
            Spacer()
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button("all sources") { model.filterSource = "all" }
            ForEach(model.report?.sources ?? [], id: \.name) { s in
                Button(s.name) { model.filterSource = s.name }
            }
        } label: {
            Label(model.filterSource == "all" ? "all sources" : model.filterSource,
                  systemImage: "line.3.horizontal.decrease")
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(BrowserTheme.mintInk.opacity(0.4), lineWidth: 1))
    }

    private var rangeMenu: some View {
        Menu {
            ForEach([(0, "all time"), (7, "last 7 days"), (30, "last 30 days"),
                     (90, "last 90 days")], id: \.0) { d, label in
                Button(label) { model.filterDays = d }
            }
        } label: {
            Label(rangeLabel, systemImage: "calendar")
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(BrowserTheme.mintInk.opacity(0.4), lineWidth: 1))
    }

    private var rangeLabel: String {
        model.filterDays == 0 ? "all time" : "last \(model.filterDays) days"
    }
}

/// Proportional bar for ranked lists.
struct ShareBar: View {
    let fraction: Double
    var color: Color = BrowserTheme.mintInk

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.12))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(3, geo.size.width
                        * min(1, fraction)))
            }
        }
    }
}

extension View {
    /// Use packaged fonts when available; missing optional fonts must not trap.
    func browserTheme(_ palette: SMPalette) -> some View {
        _ = BrowserUIResources.loaded
        return environment(\.smPalette, palette)
            .tint(palette.brand)
            .foregroundStyle(palette.foreground)
            .font(.custom(palette.sansFont, size: 14, relativeTo: .body))
            .background(palette.background.ignoresSafeArea())
            .preferredColorScheme(palette.isDark ? .dark : .light)
    }
}
