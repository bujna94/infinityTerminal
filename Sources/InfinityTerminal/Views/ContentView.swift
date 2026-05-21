import SwiftUI

// MARK: - Scroll-offset preference key

/// Reads the primary-axis scroll position from the column stack's geometry
/// relative to the named coordinate space on the ScrollView.
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Custom layouts
//
// These custom Layouts (rather than stacks) push concrete proposed sizes down
// to the NSViewRepresentable panes: they call `place(at:proposal:)` with an
// exact ProposedViewSize, and SwiftUI forwards that size to the NSView so
// SwiftTerm's setFrameSize fires every time the parent resizes. Plain stacks
// left SwiftTerm stuck at its initial 0×0 grid.

/// Outer layout for the column row in the ScrollView. The first and last
/// subviews are the edge "+" buttons (when present); everything in between
/// is a column. `hasLeadingEdge` / `hasTrailingEdge` let callers omit either
/// edge — e.g. vertical mode hides the top "+" so only the bottom one shows.
private struct GridStripLayout: Layout {
    var columnExtent: CGFloat
    var edgeButtonSize: CGFloat = 28
    var crossExtent: CGFloat
    var hasLeadingEdge: Bool = true
    var hasTrailingEdge: Bool = true

    private var edgeCount: Int {
        (hasLeadingEdge ? 1 : 0) + (hasTrailingEdge ? 1 : 0)
    }

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let columnCount = max(0, subviews.count - edgeCount)
        let primary = CGFloat(edgeCount) * edgeButtonSize + CGFloat(columnCount) * columnExtent
        return CGSize(width: primary, height: crossExtent)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let lastIdx = subviews.count - 1
        var x = bounds.minX
        let edgeProp = ProposedViewSize(width: edgeButtonSize, height: bounds.height)
        let colProp = ProposedViewSize(width: columnExtent, height: bounds.height)
        for (i, s) in subviews.enumerated() {
            let isLeadingEdge  = (i == 0 && hasLeadingEdge)
            let isTrailingEdge = (i == lastIdx && hasTrailingEdge)
            let isEdge = isLeadingEdge || isTrailingEdge
            s.place(at: CGPoint(x: x, y: bounds.minY),
                    proposal: isEdge ? edgeProp : colProp)
            x += isEdge ? edgeButtonSize : columnExtent
        }
    }
}

/// Inner layout for the panes within a single column. Splits the available
/// space evenly along the cross axis of the grid orientation — unless one pane
/// is maximized, in which case it takes all the space except a thin strip left
/// for the collapsed neighbor.
struct ColumnPanesLayout: Layout {
    /// Index of the pane expanded to fill the column, or nil for an even split.
    var maximizedIndex: Int? = nil

    /// Height reserved for the collapsed neighbor's restore strip.
    static let collapsedExtent: CGFloat = 30

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        return proposal.replacingUnspecifiedDimensions(by: .init(width: 400, height: 400))
    }

    /// Per-pane extent along the split axis, honoring a maximized pane.
    static func extents(total: CGFloat, count: Int, maximizedIndex: Int?) -> [CGFloat] {
        guard count > 0 else { return [] }
        if let m = maximizedIndex, count == 2, m >= 0, m < 2 {
            let collapsed = min(collapsedExtent, total)
            var e = [CGFloat](repeating: 0, count: count)
            e[m] = max(0, total - collapsed)
            e[1 - m] = collapsed
            return e
        }
        return [CGFloat](repeating: total / CGFloat(count), count: count)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let heights = Self.extents(total: bounds.height, count: count, maximizedIndex: maximizedIndex)
        var y = bounds.minY
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: bounds.minX, y: y),
                    proposal: ProposedViewSize(width: bounds.width, height: heights[i]))
            y += heights[i]
        }
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var gridModel: TerminalGridModel

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollTarget: UUID? = nil
    @State private var scrollAnchor: UnitPoint = .leading
    @State private var nativeScroll: NSScrollView? = nil
    @State private var minimapDragFraction: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                mainLayout(geo: geo)

                if gridModel.showShortcuts {
                    ShortcutsView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: gridModel.showMinimap)
            .animation(.easeInOut(duration: 0.15), value: gridModel.showShortcuts)
        }
        .background(Color(red: 0.059, green: 0.067, blue: 0.090))
        .onReceive(NotificationCenter.default.publisher(for: .jumpToStart)) { _ in jumpToStart() }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToHome))  { _ in jumpToHome() }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToStartInstant)) { _ in
            if let sv = nativeScroll {
                sv.contentView.scroll(to: NSPoint(x: 28, y: 0))
                sv.reflectScrolledClipView(sv.contentView)
                scrollOffset = 28
            } else {
                jumpToStart()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToEnd))         { _ in jumpToEnd() }
        .onReceive(NotificationCenter.default.publisher(for: .scrollColumnLeft))  { _ in stepColumn(by: -1) }
        .onReceive(NotificationCenter.default.publisher(for: .scrollColumnRight)) { _ in stepColumn(by: +1) }
    }

    // MARK: - Layout

    private func mainLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ToolbarView { jumpToHome() }

            gridRow(geo: geo)
                .frame(maxHeight: .infinity)

            if gridModel.showMinimap {
                let contentW = CGFloat(gridModel.columns.count) * columnExtent(geo: geo) + 56
                let vpW      = geo.size.width
                let maxScroll = max(0, contentW - vpW)
                let indicatorOffset = minimapDragFraction.map { $0 * maxScroll } ?? scrollOffset
                MinimapView(
                    scrollOffset: indicatorOffset,
                    contentWidth: contentW,
                    viewportWidth: vpW,
                    onScrollToFraction: { fraction in
                        minimapDragFraction = fraction
                        guard let sv = nativeScroll, let doc = sv.documentView else { return }
                        let maxOff = max(0, doc.frame.width - sv.contentSize.width)
                        sv.contentView.scroll(to: NSPoint(x: fraction * maxOff, y: 0))
                        sv.reflectScrolledClipView(sv.contentView)
                    },
                    onDragEnded: { minimapDragFraction = nil }
                )
                .frame(height: gridModel.minimapHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func gridRow(geo: GeometryProxy) -> some View {
        scrollGrid(geo: geo)
    }

    private func scrollGrid(geo: GeometryProxy) -> some View {
        let columnExt = columnExtent(geo: geo)
        // Reserve space for the toolbar (38pt) and minimap (when shown).
        let toolbar: CGFloat = 38
        let minimapH = gridModel.showMinimap ? gridModel.minimapHeight : 0
        let availableH = geo.size.height - toolbar - minimapH

        let layout = GridStripLayout(
            columnExtent: columnExt,
            crossExtent: availableH,
            hasLeadingEdge: true,
            hasTrailingEdge: true
        )

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                layout {
                    EdgeButton(side: .leading) {
                        gridModel.addColumnLeft()
                        scrollAnchor = .leading
                        scrollTarget = gridModel.columns.first?.id
                    }

                    ForEach(Array(gridModel.columns.enumerated()), id: \.element.id) { idx, col in
                        TerminalColumnView(column: col, columnIndex: idx)
                            .id(col.id)
                    }

                    EdgeButton(side: .trailing) {
                        gridModel.addColumnRight()
                        scrollAnchor = .trailing
                        scrollTarget = gridModel.columns.last?.id
                    }
                }
                .animation(.spring(duration: 0.28), value: gridModel.columns.map { $0.id })
                .background(Color(red: 0.059, green: 0.067, blue: 0.090))
                .background(
                    GeometryReader { inner in
                        let f = inner.frame(in: .named("gridscroll"))
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: max(0, -f.minX)
                        )
                    }
                )
                .background(ScrollViewSpy { sv in
                    nativeScroll = sv
                    if let target = gridModel.pendingScrollRestore {
                        gridModel.pendingScrollRestore = nil
                        DispatchQueue.main.async {
                            sv.contentView.scroll(to: NSPoint(x: target, y: 0))
                            sv.reflectScrolledClipView(sv.contentView)
                            scrollOffset = target
                        }
                    }
                })
            }
            .scrollBounceBehavior(.always, axes: .horizontal)
            .coordinateSpace(name: "gridscroll")
            .onPreferenceChange(ScrollOffsetKey.self) { newValue in
                scrollOffset = newValue
                gridModel.lastScrollLeft = newValue
            }
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: scrollAnchor)
                    }
                    scrollTarget = nil
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    if gridModel.pendingScrollRestore == nil && gridModel.lastScrollLeft <= 0 {
                        scrollAnchor = .leading
                        scrollTarget = gridModel.columns.first?.id
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func columnExtent(geo: GeometryProxy) -> CGFloat {
        max(400, geo.size.width / 2)
    }

    private func jumpToStart() {
        if let first = gridModel.columns.first {
            scrollAnchor = .leading
            scrollTarget = first.id
        }
    }

    private func jumpToHome() {
        guard let homeID = gridModel.homeColumnID,
              gridModel.columns.contains(where: { $0.id == homeID }) else {
            jumpToStart()
            return
        }
        scrollAnchor = .leading
        scrollTarget = homeID
    }

    private func jumpToEnd() {
        if let last = gridModel.columns.last {
            scrollAnchor = .trailing
            scrollTarget = last.id
        }
    }

    private func stepColumn(by delta: Int) {
        guard !gridModel.columns.isEmpty else { return }
        let windowW = NSApp.mainWindow?.frame.size.width ?? 800
        let primary = max(1, max(400, windowW / 2))
        let current = Int(scrollOffset / primary)
        let target  = max(0, min(gridModel.columns.count - 1, current + delta))
        scrollAnchor = delta > 0 ? .trailing : .leading
        scrollTarget = gridModel.columns[target].id
    }
}

// MARK: - NSScrollView capture helper

private struct ScrollViewSpy: NSViewRepresentable {
    let onCapture: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            var cur: NSView? = v
            while let view = cur {
                if let sv = view as? NSScrollView { onCapture(sv); return }
                cur = view.superview
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Edge button

enum EdgeSide { case leading, trailing }

struct EdgeButton: View {
    let side: EdgeSide
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("＋")
                .font(.system(size: 18))
                .foregroundColor(isHovered ? Color(white: 0.85) : Color(white: 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isHovered
                        ? Color(red: 0.086, green: 0.102, blue: 0.141).opacity(0.95)
                        : Color(red: 0.086, green: 0.102, blue: 0.141).opacity(0.90)
                )
                .overlay(alignment: side == .leading ? .trailing : .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

