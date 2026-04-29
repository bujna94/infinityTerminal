import SwiftUI

/// A compact overview of all columns shown at the bottom of the window.
/// `onScrollToFraction` fires with a 0…1 fraction for continuous smooth scrolling.
struct MinimapView: View {
    @EnvironmentObject var gridModel: TerminalGridModel

    let scrollOffset: CGFloat
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let onScrollToFraction: (CGFloat) -> Void
    let onDragEnded: () -> Void

    private let minimapBg = Color(red: 10.0/255.0, green: 12.0/255.0, blue: 18.0/255.0).opacity(0.92)

    /// Scroll offset captured when a drag begins on the indicator.
    @State private var dragStartOffset: CGFloat = -1
    /// Whether the current gesture started on the indicator (nil = not yet determined).
    @State private var draggingIndicator: Bool? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Resizer — 8px tall, shows a centered 36×3pt handle
            ZStack {
                Color.clear
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 3)
            }
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newH = gridModel.minimapHeight - value.translation.height
                        gridModel.minimapHeight = max(40, min(200, newH))
                    }
            )
            .cursor(.resizeUpDown)

            // Column thumbnails + viewport indicator
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(gridModel.columns) { column in
                        VStack(spacing: 0) {
                            ForEach(column.sessions) { session in
                                MinimapPane(session: session)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    viewportIndicator(geo: geo)
                }
                .contentShape(Rectangle())
                .gesture(minimapDrag(geo: geo))
            }
            .frame(maxHeight: .infinity)
        }
        .background(minimapBg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    // MARK: - Drag gesture

    private func minimapDrag(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard geo.size.width > 0, contentWidth > viewportWidth else { return }
                let ratio     = geo.size.width / contentWidth
                let indW      = max(20, viewportWidth * ratio)
                let maxX      = geo.size.width - indW
                guard maxX > 0 else { return }

                // Decide drag type on the very first event of this gesture
                if draggingIndicator == nil {
                    let indX  = min(maxX, max(0, scrollOffset * ratio))
                    let sx    = value.startLocation.x
                    // 8pt slop so edge of indicator is easy to grab
                    draggingIndicator = sx >= indX - 8 && sx <= indX + indW + 8
                }

                if draggingIndicator == true {
                    // ── Indicator drag: move by translation from start ──────────
                    if dragStartOffset < 0 { dragStartOffset = scrollOffset }
                    let maxScroll  = contentWidth - viewportWidth
                    let scrollDelta = value.translation.width * contentWidth / geo.size.width
                    let newScroll   = (dragStartOffset + scrollDelta).clamped(to: 0...maxScroll)
                    onScrollToFraction(maxScroll > 0 ? newScroll / maxScroll : 0)
                } else {
                    // ── Background click/drag: center indicator under finger ────
                    let newX    = (value.location.x - indW / 2).clamped(to: 0...maxX)
                    onScrollToFraction(newX / maxX)
                }
            }
            .onEnded { _ in
                dragStartOffset   = -1
                draggingIndicator = nil
                onDragEnded()
            }
    }

    // MARK: - Viewport indicator

    @ViewBuilder
    private func viewportIndicator(geo: GeometryProxy) -> some View {
        if contentWidth > viewportWidth, contentWidth > 0, geo.size.width > 0 {
            let ratio      = geo.size.width / contentWidth
            let indicatorW = max(20, viewportWidth * ratio)
            let maxX       = geo.size.width - indicatorW
            let indicatorX = min(maxX, max(0, scrollOffset * ratio))
            let vInset: CGFloat = 6

            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.310, green: 0.451, blue: 1.0).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0.310, green: 0.451, blue: 1.0).opacity(0.9), lineWidth: 1)
                )
                .frame(width: indicatorW, height: geo.size.height - vInset * 2)
                .offset(x: indicatorX, y: vInset)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Per-pane thumbnail

struct MinimapPane: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        ZStack {
            Color(session.backgroundColor)

            VStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.13))
                            .frame(
                                width: row % 3 == 0 ? nil : (row % 3 == 1 ? 50 : 70),
                                height: 2
                            )
                            .frame(maxWidth: row % 3 == 0 ? .infinity : nil)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 5)
                }
            }
            .padding(.vertical, 5)
        }
        .clipped()
    }
}

// MARK: - Cursor helper

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
