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
// The orientation toggle has to keep the cached PTY views alive. AnyLayout
// preserved view identity at the SwiftUI level but failed to push concrete
// proposed sizes down to the NSViewRepresentable, leaving SwiftTerm stuck at
// its initial 0×0 grid even after the parent grew. A custom Layout fixes
// that: it calls `place(at:proposal:)` with an exact ProposedViewSize, and
// SwiftUI forwards that size to the NSView so SwiftTerm's setFrameSize fires
// every time.

/// Outer layout for the column row in the ScrollView. The first and last
/// subviews are the edge "+" buttons (when present); everything in between
/// is a column. `hasLeadingEdge` / `hasTrailingEdge` let callers omit either
/// edge — e.g. vertical mode hides the top "+" so only the bottom one shows.
private struct GridStripLayout: Layout {
    var orientation: ScrollOrientation
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
        if orientation == .horizontal {
            return CGSize(width: primary, height: crossExtent)
        } else {
            return CGSize(width: crossExtent, height: primary)
        }
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let lastIdx = subviews.count - 1
        if orientation == .horizontal {
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
        } else {
            var y = bounds.minY
            let edgeProp = ProposedViewSize(width: bounds.width, height: edgeButtonSize)
            let colProp = ProposedViewSize(width: bounds.width, height: columnExtent)
            for (i, s) in subviews.enumerated() {
                let isLeadingEdge  = (i == 0 && hasLeadingEdge)
                let isTrailingEdge = (i == lastIdx && hasTrailingEdge)
                let isEdge = isLeadingEdge || isTrailingEdge
                s.place(at: CGPoint(x: bounds.minX, y: y),
                        proposal: isEdge ? edgeProp : colProp)
                y += isEdge ? edgeButtonSize : columnExtent
            }
        }
    }
}

/// Inner layout for the panes within a single column. Splits the available
/// space evenly along the cross axis of the grid orientation.
struct ColumnPanesLayout: Layout {
    var orientation: ScrollOrientation

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        return proposal.replacingUnspecifiedDimensions(by: .init(width: 400, height: 400))
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        if orientation == .horizontal {
            let h = bounds.height / CGFloat(count)
            for (i, s) in subviews.enumerated() {
                s.place(at: CGPoint(x: bounds.minX,
                                    y: bounds.minY + CGFloat(i) * h),
                        proposal: ProposedViewSize(width: bounds.width, height: h))
            }
        } else {
            let w = bounds.width / CGFloat(count)
            for (i, s) in subviews.enumerated() {
                s.place(at: CGPoint(x: bounds.minX + CGFloat(i) * w,
                                    y: bounds.minY),
                        proposal: ProposedViewSize(width: w, height: bounds.height))
            }
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
                let pt = gridModel.scrollOrientation == .horizontal
                    ? NSPoint(x: 28, y: 0) : NSPoint(x: 0, y: 28)
                sv.contentView.scroll(to: pt)
                sv.reflectScrolledClipView(sv.contentView)
                scrollOffset = 28
            } else {
                jumpToStart()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToEnd))         { _ in jumpToEnd() }
        .onReceive(NotificationCenter.default.publisher(for: .scrollColumnLeft))  { _ in stepColumn(by: -1) }
        .onReceive(NotificationCenter.default.publisher(for: .scrollColumnRight)) { _ in stepColumn(by: +1) }
        .onChange(of: gridModel.scrollOrientation) { _, newOrientation in
            scrollOffset = 0
            gridModel.lastScrollLeft = 0
            DispatchQueue.main.async {
                if let sv = nativeScroll {
                    sv.contentView.scroll(to: .zero)
                    sv.reflectScrolledClipView(sv.contentView)
                }
                scrollAnchor = newOrientation == .horizontal ? .leading : .top
                scrollTarget = gridModel.columns.first?.id
            }
        }
    }

    // MARK: - Layout

    private func mainLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ToolbarView { jumpToHome() }

            gridRow(geo: geo)
                .frame(maxHeight: .infinity)

            if gridModel.showMinimap && gridModel.scrollOrientation == .horizontal {
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
        let isH = gridModel.scrollOrientation == .horizontal
        let columnExt = columnExtent(geo: geo)
        // Reserve space for toolbar (38pt). The minimap is hidden in vertical
        // mode, so subtract its height only when applicable.
        let toolbar: CGFloat = 38
        let minimapH = (isH && gridModel.showMinimap) ? gridModel.minimapHeight : 0
        let availableW = geo.size.width
        let availableH = geo.size.height - toolbar - minimapH

        let layout = GridStripLayout(
            orientation: gridModel.scrollOrientation,
            columnExtent: columnExt,
            crossExtent: isH ? availableH : availableW,
            hasLeadingEdge: isH,
            hasTrailingEdge: true
        )

        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                layout {
                    // Vertical mode hides the top "+" — only the bottom one
                    // is shown. Horizontal keeps both left and right.
                    if isH {
                        EdgeButton(orientation: .horizontal, side: .leading) {
                            gridModel.addColumnLeft()
                            scrollAnchor = .leading
                            scrollTarget = gridModel.columns.first?.id
                        }
                    }

                    ForEach(Array(gridModel.columns.enumerated()), id: \.element.id) { idx, col in
                        TerminalColumnView(column: col, columnIndex: idx)
                            .id(col.id)
                    }

                    EdgeButton(orientation: isH ? .horizontal : .vertical, side: .trailing) {
                        gridModel.addColumnRight()
                        scrollAnchor = isH ? .trailing : .bottom
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
                            value: max(0, isH ? -f.minX : -f.minY)
                        )
                    }
                )
                .background(ScrollViewSpy { sv in
                    nativeScroll = sv
                    if let target = gridModel.pendingScrollRestore {
                        gridModel.pendingScrollRestore = nil
                        DispatchQueue.main.async {
                            let pt = isH ? NSPoint(x: target, y: 0)
                                         : NSPoint(x: 0, y: target)
                            sv.contentView.scroll(to: pt)
                            sv.reflectScrolledClipView(sv.contentView)
                            scrollOffset = target
                        }
                    }
                })
            }
            .scrollBounceBehavior(.always, axes: isH ? .horizontal : .vertical)
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
                        scrollAnchor = isH ? .leading : .top
                        scrollTarget = gridModel.columns.first?.id
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func columnExtent(geo: GeometryProxy) -> CGFloat {
        if gridModel.scrollOrientation == .horizontal {
            return max(400, geo.size.width / 2)
        } else {
            // Subtract toolbar so two columns fit cleanly inside the viewport.
            return max(300, (geo.size.height - 38) / 2)
        }
    }

    private func jumpToStart() {
        if let first = gridModel.columns.first {
            scrollAnchor = gridModel.scrollOrientation == .horizontal ? .leading : .top
            scrollTarget = first.id
        }
    }

    private func jumpToHome() {
        guard let homeID = gridModel.homeColumnID,
              gridModel.columns.contains(where: { $0.id == homeID }) else {
            jumpToStart()
            return
        }
        scrollAnchor = gridModel.scrollOrientation == .horizontal ? .leading : .top
        scrollTarget = homeID
    }

    private func jumpToEnd() {
        if let last = gridModel.columns.last {
            scrollAnchor = gridModel.scrollOrientation == .horizontal ? .trailing : .bottom
            scrollTarget = last.id
        }
    }

    private func stepColumn(by delta: Int) {
        guard !gridModel.columns.isEmpty else { return }
        let primary: CGFloat
        if gridModel.scrollOrientation == .horizontal {
            let windowW = NSApp.mainWindow?.frame.size.width ?? 800
            primary = max(1, max(400, windowW / 2))
        } else {
            let windowH = NSApp.mainWindow?.frame.size.height ?? 600
            primary = max(1, max(300, windowH / 2))
        }
        let current = Int(scrollOffset / primary)
        let target  = max(0, min(gridModel.columns.count - 1, current + delta))
        if gridModel.scrollOrientation == .horizontal {
            scrollAnchor = delta > 0 ? .trailing : .leading
        } else {
            scrollAnchor = delta > 0 ? .bottom : .top
        }
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

enum EdgeOrientation { case horizontal, vertical }
enum EdgeSide { case leading, trailing }

struct EdgeButton: View {
    let orientation: EdgeOrientation
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
                .overlay(alignment: innerEdge) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(
                            width: orientation == .horizontal ? 1 : nil,
                            height: orientation == .horizontal ? nil : 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var innerEdge: Alignment {
        switch (orientation, side) {
        case (.horizontal, .leading):  return .trailing
        case (.horizontal, .trailing): return .leading
        case (.vertical,   .leading):  return .bottom
        case (.vertical,   .trailing): return .top
        }
    }
}

