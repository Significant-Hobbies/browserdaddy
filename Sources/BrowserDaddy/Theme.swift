import SwiftUI
import SaaSMakerUI

/// Daddy series theme — same palette as StorageDaddy/PerformanceDaddy.
enum BrowserTheme {
    static let palette: SMPalette = {
        var palette = SMPalette.ink.brand(DaddyPalette.mint, foreground: .black)
        palette.background = DaddyPalette.canvas
        palette.surface = DaddyPalette.canvas
        palette.card = DaddyPalette.canvas
        palette.foreground = DaddyPalette.ink
        palette.mutedForeground = DaddyPalette.secondaryInk
        palette.hairline = DaddyPalette.secondaryInk.opacity(0.18)
        palette.success = DaddyPalette.mint
        palette.destructive = DaddyPalette.coral
        palette.warning = DaddyPalette.amber
        palette.radius = 14
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

/// Shared Daddy-series control pattern.
struct DaddyButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.black : BrowserTheme.mintInk)
            .background(prominent ? BrowserTheme.mintInk
                        : isHovering && isEnabled ? BrowserTheme.mint : Color.black,
                        in: shape)
            .overlay(shape
                .stroke(BrowserTheme.mintInk.opacity(prominent ? 1
                    : isHovering && isEnabled ? 0.7 : 0.35),
                        lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DaddyButtonStyle(prominent: true).makeBody(configuration: configuration)
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
        SMCard(padding: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    bandHeading.frame(width: 124, alignment: .leading)
                    if !collapsed {
                        Divider()
                        content.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    bandHeading
                    if !collapsed {
                        Divider()
                        content.frame(maxWidth: .infinity, alignment: .leading)
                    }
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right"
                                                : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(BrowserTheme.mintInk)
                    SMSectionHeader(label, size: 14)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(BrowserTheme.secondaryInk.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
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
