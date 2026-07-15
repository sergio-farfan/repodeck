import AppKit
import SwiftUI

/// Fractional bounds a `VerticalSplit` will clamp its `fraction` binding to,
/// so neither region can be dragged to zero height.
private let splitMinFraction = 0.15
private let splitMaxFraction = 0.85
private let splitHandleHeight: CGFloat = 8

/// Reusable draggable vertical split container: `top` gets `fraction` of the
/// available height (minus the handle), `bottom` gets the rest. Content-
/// independent — either side can be empty, scrollable, or anything else; the
/// split only manages height allocation between them.
///
/// When `isSplit` is false the container collapses to just `top` at full
/// height (no handle, no `bottom`). Crucially, `top` stays the VStack's first
/// child in both states — only the trailing handle/`bottom` are conditional —
/// so toggling `isSplit` never changes `top`'s structural identity and its
/// subtree keeps its `@State` (scroll position, focus). Callers therefore
/// mount an optional bottom pane by flipping `isSplit` rather than swapping
/// `top` in and out of the view tree.
struct VerticalSplit<Top: View, Bottom: View>: View {
    /// Fraction of available height given to `top`. Owned and persisted by
    /// the caller (e.g. via `@AppStorage`) — this view only reads/writes it.
    @Binding var fraction: Double
    /// When false, only `top` is shown (full height); the handle and `bottom`
    /// are omitted without disturbing `top`'s identity.
    let isSplit: Bool
    let top: Top
    let bottom: Bottom

    init(
        fraction: Binding<Double>,
        isSplit: Bool = true,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self._fraction = fraction
        self.isSplit = isSplit
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let contentHeight = max(totalHeight - splitHandleHeight, 0)
            let topHeight = clampedFraction * contentHeight
            let bottomHeight = contentHeight - topHeight

            VStack(spacing: 0) {
                top
                    .frame(height: isSplit ? topHeight : totalHeight)

                if isSplit {
                    SplitHandle(fraction: $fraction, totalHeight: totalHeight)

                    bottom
                        .frame(height: bottomHeight)
                }
            }
            .frame(height: totalHeight)
        }
    }

    private var clampedFraction: Double {
        min(max(fraction, splitMinFraction), splitMaxFraction)
    }
}

/// The draggable bar between `top` and `bottom`: a subtle separator line
/// with a centered grip, a resize cursor on hover/drag, and a drag gesture
/// that maps vertical translation to a delta from a drag-start baseline
/// (never accumulated across `onChanged` calls, so it can't drift).
private struct SplitHandle: View {
    @Binding var fraction: Double
    let totalHeight: CGFloat

    @Environment(\.theme) private var theme

    @State private var dragStartFraction: Double?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            Capsule()
                .fill((isHovering || isDragging) ? theme.accent.opacity(0.8) : Color.secondary.opacity(0.5))
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: splitHandleHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            syncCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    syncCursor()

                    guard totalHeight > 0 else { return }
                    // Capture the baseline once at drag start; every
                    // subsequent call re-derives the fraction from that same
                    // baseline plus the gesture's total translation so far
                    // (DragGesture.translation is cumulative from drag
                    // start), avoiding any per-callback drift.
                    let start = dragStartFraction ?? fraction
                    dragStartFraction = start
                    let delta = value.translation.height / totalHeight
                    fraction = min(max(start + delta, splitMinFraction), splitMaxFraction)
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartFraction = nil
                    syncCursor()
                }
        )
        .onDisappear {
            // If the detail pane is torn down while the handle is hovered or
            // mid-drag (selection removed by a background rescan, last folder
            // removed), onHover(false)/onEnded never fire. NSCursor's stack is
            // process-wide, so an unbalanced push would corrupt the cursor for
            // the rest of the session — pop it here and reset drag state.
            isHovering = false
            isDragging = false
            dragStartFraction = nil
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    /// Keeps `NSCursor.push()`/`.pop()` in 1:1 balance: pushes once when
    /// hovering-or-dragging first becomes true, pops once when both become
    /// false. Tracking the combined state (rather than pushing/popping
    /// straight from `onHover`) keeps the resize cursor visible for the
    /// whole drag even if the pointer strays outside the thin handle strip.
    private func syncCursor() {
        let shouldShowResize = isHovering || isDragging
        if shouldShowResize, !cursorPushed {
            NSCursor.resizeUpDown.push()
            cursorPushed = true
        } else if !shouldShowResize, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
