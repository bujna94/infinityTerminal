import SwiftUI

// MARK: - Scroll-offset preference key
// Reads the horizontal scroll position from the column stack's geometry
// relative to the named coordinate space on the ScrollView.
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var gridModel: TerminalGridModel

    /// Actual horizontal scroll offset, kept in sync via PreferenceKey.
    @State private var scrollOffset: CGFloat = 0
    /// Set to a column UUID to trigger a smooth programmatic scroll.
    @State private var scrollTarget: UUID? = nil
    /// Anchor for the next programmatic scroll (.leading or .trailing).
    @State private var scrollAnchor: UnitPoint = .leading
    /// Reference to the underlying NSScrollView, captured once for smooth minimap drag.
    @State private var nativeScroll: NSScrollView? = nil
    /// While the minimap indicator is being dragged, holds the 0…1 fraction so the
    /// indicator position updates immediately without waiting for scrollOffset to sync.
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
        .onReceive(NotificationCenter.default.publisher(for: .jumpToStart)) { _ in
            jumpToStart()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToStartInstant)) { _ in
            // After reset: snap instantly via NSScrollView so there's no reversed scroll animation.
            if let sv = nativeScroll {
                sv.contentView.scroll(to: NSPoint(x: 28, y: 0))
                sv.reflectScrolledClipView(sv.contentView)
                scrollOffset = 28
            } else {
                jumpToStart()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToEnd)) { _ in
            jumpToEnd()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollColumnLeft)) { _ in
            stepColumn(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollColumnRight)) { _ in
            stepColumn(by: +1)
        }
    }

    // MARK: - Layout

    private func mainLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ToolbarView { jumpToStart() }

            gridRow(geo: geo)
                .frame(maxHeight: .infinity)

            if gridModel.showMinimap {
                let contentW = CGFloat(gridModel.columns.count) * columnWidth(geo: geo) + 56 // columns + two buttons
                let vpW      = geo.size.width
                let maxScroll = max(0, contentW - vpW)
                // During a minimap drag, use the drag fraction directly so the indicator
                // moves in sync with the finger rather than waiting for scrollOffset to sync.
                let indicatorOffset = minimapDragFraction.map { $0 * maxScroll } ?? scrollOffset
                MinimapView(
                    scrollOffset: indicatorOffset,
                    contentWidth: contentW,
                    viewportWidth: vpW,
                    onScrollToFraction: { fraction in
                        minimapDragFraction = fraction
                        guard let sv = nativeScroll,
                              let doc = sv.documentView else { return }
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
        let columnW = columnWidth(geo: geo)

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    EdgeButton(side: .left) {
                        gridModel.addColumnLeft()
                        scrollAnchor = .leading
                        scrollTarget = gridModel.columns.first?.id
                    }
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)

                    ForEach(Array(gridModel.columns.enumerated()), id: \.element.id) { idx, col in
                        TerminalColumnView(column: col, columnIndex: idx)
                        .frame(width: columnW)
                        .frame(maxHeight: .infinity)
                        .id(col.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                    }

                    EdgeButton(side: .right) {
                        gridModel.addColumnRight()
                        scrollAnchor = .trailing
                        scrollTarget = gridModel.columns.last?.id
                    }
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)
                }
                .animation(.spring(duration: 0.28), value: gridModel.columns.map { $0.id })
                .frame(maxHeight: .infinity)
                .background(Color(red: 0.059, green: 0.067, blue: 0.090))
                // Track real scroll offset via coordinate space
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: max(0, -inner.frame(in: .named("hscroll")).minX)
                        )
                    }
                )
                // Capture the NSScrollView once for smooth minimap drag scrolling
                .background(ScrollViewSpy { sv in nativeScroll = sv })
            }
            .scrollBounceBehavior(.always, axes: .horizontal)
            .coordinateSpace(name: "hscroll")
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: scrollAnchor)
                    }
                    scrollTarget = nil
                }
            }
            .onAppear {
                // Scroll past the left + button so it starts hidden off-screen.
                DispatchQueue.main.async {
                    scrollAnchor = .leading
                    scrollTarget = gridModel.columns.first?.id
                }
            }
        }
    }

    // MARK: - Helpers

    /// Each column is half the viewport width. Two columns fill the visible area exactly.
    private func columnWidth(geo: GeometryProxy) -> CGFloat {
        return max(400, geo.size.width / 2)
    }

    private func jumpToStart() {
        if let first = gridModel.columns.first {
            scrollAnchor = .leading
            scrollTarget = first.id
        }
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
        let colW = max(1, max(400, windowW / 2))
        let current = Int(scrollOffset / colW)
        let target  = max(0, min(gridModel.columns.count - 1, current + delta))
        scrollAnchor = delta > 0 ? .trailing : .leading
        scrollTarget = gridModel.columns[target].id
    }
}

// MARK: - NSScrollView capture helper

/// Walks the ancestor chain from inside the SwiftUI ScrollView content to find
/// the backing NSScrollView. Called once; the result is stored in `nativeScroll`.
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

enum EdgeSide { case left, right }

struct EdgeButton: View {
    let side: EdgeSide
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("＋")  // fullwidth plus U+FF0B
                .font(.system(size: 18))
                .foregroundColor(isHovered ? Color(white: 0.85) : Color(white: 0.45))
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .background(
                    isHovered
                        ? Color(red: 0.086, green: 0.102, blue: 0.141).opacity(0.95)
                        : Color(red: 0.086, green: 0.102, blue: 0.141).opacity(0.90)
                )
                // Border on the inner edge of each button
                .overlay(alignment: side == .left ? .trailing : .leading) {
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
