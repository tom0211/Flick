import SwiftUI

struct TileMetrics: Equatable {
    var previewWidth: CGFloat = 230
    var previewHeight: CGFloat = 144

    static let tilePadding: CGFloat = 10
    static let labelGap: CGFloat = 8
    static let labelHeight: CGFloat = 18
    static let spacing: CGFloat = 6
    static let outerPadding: CGFloat = 16
    static let hintGap: CGFloat = 10
    static let hintHeight: CGFloat = 18
    /// Concentric with the panel: panel radius minus the padding between them.
    static var tileCornerRadius: CGFloat { panelCornerRadius - outerPadding }
    static var previewCornerRadius: CGFloat { max(tileCornerRadius - tilePadding, 6) }
    /// macOS 26 draws windows and glass with noticeably rounder corners.
    static var panelCornerRadius: CGFloat {
        if #available(macOS 26.0, *) { 30 } else { 26 }
    }

    var tileWidth: CGFloat { previewWidth + 2 * Self.tilePadding }
    var tileHeight: CGFloat { previewHeight + Self.labelGap + Self.labelHeight + 2 * Self.tilePadding }
}

/// Tile size, column count and panel size for a given number of items on a given screen.
struct SwitcherLayout {
    let metrics: TileMetrics
    let columns: Int
    let size: CGSize
    let scrolls: Bool

    static func fitting(count: Int, in available: CGSize) -> SwitcherLayout {
        let count = max(count, 1)
        let maxWidth = available.width * 0.9
        let maxHeight = available.height * 0.85
        let chrome = 2 * TileMetrics.outerPadding + TileMetrics.hintGap + TileMetrics.hintHeight

        var smallest: (metrics: TileMetrics, columns: Int)?
        // Shrink tiles until everything fits; past the smallest size, cap the height and scroll.
        for scale in stride(from: 1.0, through: 0.6, by: -0.05) {
            var metrics = TileMetrics()
            metrics.previewWidth = (metrics.previewWidth * scale).rounded()
            metrics.previewHeight = (metrics.previewHeight * scale).rounded()
            let fit = Int((maxWidth - 2 * TileMetrics.outerPadding + TileMetrics.spacing) / (metrics.tileWidth + TileMetrics.spacing))
            let columns = max(1, min(count, fit))
            let rows = (count + columns - 1) / columns
            let height = chrome + CGFloat(rows) * metrics.tileHeight + CGFloat(rows - 1) * TileMetrics.spacing
            if height <= maxHeight {
                return SwitcherLayout(metrics: metrics, columns: columns, size: CGSize(width: width(metrics, columns), height: height), scrolls: false)
            }
            smallest = (metrics, columns)
        }
        let (metrics, columns) = smallest!
        return SwitcherLayout(metrics: metrics, columns: columns, size: CGSize(width: width(metrics, columns), height: maxHeight.rounded()), scrolls: true)
    }

    private static func width(_ metrics: TileMetrics, _ columns: Int) -> CGFloat {
        2 * TileMetrics.outerPadding + CGFloat(columns) * metrics.tileWidth + CGFloat(columns - 1) * TileMetrics.spacing
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var metrics = TileMetrics()
    @Published var columns = 1
    @Published var scrolls = false
    /// Tile frames in the panel's top-left-origin coordinates, for mouse hit-testing.
    var tileFrames: [Int: CGRect] = [:]

    var selectedItem: SwitcherItem? { items.indices.contains(selection) ? items[selection] : nil }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    private static let coordinateSpace = "switcher"

    var body: some View {
        VStack(spacing: TileMetrics.hintGap) {
            if model.scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { grid }
                        .onChange(of: model.selection) { _, selection in
                            guard model.items.indices.contains(selection) else { return }
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(model.items[selection].id) }
                        }
                }
            } else {
                grid
            }
            HintBar().frame(height: TileMetrics.hintHeight)
        }
        .padding(TileMetrics.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            // Liquid Glass brings its own lit edge; the older material needs one drawn.
            if !LiquidGlass.isAvailable {
                RoundedRectangle(cornerRadius: TileMetrics.panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(TileFramesKey.self) { frames in
            MainActor.assumeIsolated { model.tileFrames = frames }
        }
        // The panel is never key by design, which would otherwise render accents in their grey, inactive form.
        .environment(\.appearsActive, true)
    }

    private var grid: some View {
        let columns = max(model.columns, 1)
        let rowStarts = Array(stride(from: 0, to: model.items.count, by: columns))
        return ZStack(alignment: .topLeading) {
            // One lens that slides from tile to tile, underneath the tiles' content.
            if model.items.indices.contains(model.selection) {
                SelectionLens(metrics: model.metrics)
                    .offset(lensOffset(for: model.selection, columns: columns))
            }
            VStack(alignment: .leading, spacing: TileMetrics.spacing) {
                ForEach(rowStarts, id: \.self) { start in
                    HStack(spacing: TileMetrics.spacing) {
                        ForEach(start..<min(start + columns, model.items.count), id: \.self) { index in
                            tile(at: index)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lensOffset(for index: Int, columns: Int) -> CGSize {
        let metrics = model.metrics
        return CGSize(
            width: CGFloat(index % columns) * (metrics.tileWidth + TileMetrics.spacing),
            height: CGFloat(index / columns) * (metrics.tileHeight + TileMetrics.spacing)
        )
    }

    private func tile(at index: Int) -> some View {
        let item = model.items[index]
        return TileView(
            item: item,
            thumbnail: item.windowID.flatMap { model.thumbnails[$0] },
            isSelected: index == model.selection,
            metrics: model.metrics
        )
        .id(item.id)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TileFramesKey.self, value: [index: geometry.frame(in: .named(Self.coordinateSpace))])
            }
        }
    }
}

private struct TileFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TileView: View {
    let item: SwitcherItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let metrics: TileMetrics

    private var previewBox: CGSize { CGSize(width: metrics.previewWidth, height: metrics.previewHeight) }
    private var isDimmed: Bool { item.isMinimized || item.isHidden || item.windowID == nil }

    var body: some View {
        VStack(spacing: TileMetrics.labelGap) {
            preview
                .frame(width: metrics.previewWidth, height: metrics.previewHeight)
            label
                .frame(width: metrics.previewWidth, height: TileMetrics.labelHeight)
        }
        .padding(TileMetrics.tilePadding)
        .frame(width: metrics.tileWidth, height: metrics.tileHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: TileMetrics.previewCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .opacity(isDimmed ? 0.5 : 1)
                .overlay(alignment: .topTrailing) { badge }
        } else if item.windowID == nil {
            // An app with no windows: just its icon, no window card.
            icon(size: min(metrics.previewHeight * 0.62, 88))
                .opacity(0.75)
        } else {
            // No capture (yet): a window-shaped card carrying the app icon.
            let card = item.windowSize.aspectFit(in: previewBox)
            RoundedRectangle(cornerRadius: TileMetrics.previewCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: TileMetrics.previewCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .overlay { icon(size: min(card.height * 0.5, 72)).opacity(isDimmed ? 0.55 : 1) }
                .frame(width: card.width, height: card.height)
                .overlay(alignment: .topTrailing) { badge }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            icon(size: 16)
            Text(item.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let text = badgeText {
            let label = Text(text)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
            Group {
                if #available(macOS 26.0, *) {
                    // A small glass pill floating over the preview, the way macOS 26 layers controls over content.
                    label.glassEffect(.regular, in: .capsule)
                } else {
                    label
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.6), in: Capsule())
                }
            }
            .padding(5)
        }
    }

    private var badgeText: String? {
        if item.isMinimized { return "Minimized" }
        if item.isHidden { return "Hidden" }
        return item.spaceLabel
    }

    private func icon(size: CGFloat) -> some View {
        Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

enum LiquidGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }
}

/// The selection highlight: an accent-tinted glass lens on macOS 26, a tinted, outlined card before that.
private struct SelectionLens: View {
    let metrics: TileMetrics
    /// The user's system accent, read directly so it never falls back to the inactive-window grey.
    private let accent = Color(nsColor: .controlAccentColor)
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TileMetrics.tileCornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Glass nested in the panel's glass drops its tint, so the accent is laid on top of the lens instead.
                shape
                    .fill(accent.opacity(0.26))
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                shape
                    .fill(accent.opacity(0.24))
                    .overlay { shape.strokeBorder(accent, lineWidth: 2) }
            }
        }
        .frame(width: metrics.tileWidth, height: metrics.tileHeight)
    }
}

private struct HintBar: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            hints([("⇥", "Next"), ("⇧⇥", "Back"), ("W", "Close"), ("M", "Minimize"), ("H", "Hide"), ("Q", "Quit"), ("esc", "Cancel")])
            hints([("W", "Close"), ("M", "Min"), ("Q", "Quit"), ("esc", "Cancel")])
            hints([("esc", "Cancel")])
        }
    }

    private func hints(_ pairs: [(key: String, label: String)]) -> some View {
        HStack(spacing: 14) {
            ForEach(pairs, id: \.key) { pair in
                HStack(spacing: 5) {
                    Text(pair.key)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(pair.label)
                        .font(.system(size: 11))
                }
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}
