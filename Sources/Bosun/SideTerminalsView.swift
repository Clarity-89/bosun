import AppKit
import BosunTerminal
import SwiftUI

/// One directory's side terminals, one above the other, in a column
/// beside the pane that the user drags wider or narrower by its leading
/// edge. Its own handle, not a split view: a split view opens a new
/// column as wide as it can, with no say over the width it starts at.
@MainActor
struct SideTerminalsView: View {
    /// Top to bottom; nil where the shell has ended.
    let panes: [TerminalPane?]
    /// A new shell for the slot at the index, whose shell ended.
    let respawn: (Int) -> Void
    @Binding var width: CGFloat
    /// The width when the drag began; the drag reports its whole distance.
    @State private var widthBeforeDrag: CGFloat?

    static let widths: ClosedRange<CGFloat> = 320...900

    var body: some View {
        HStack(spacing: 0) {
            handle
            VSplitView {
                ForEach(panes.indices, id: \.self) { index in
                    Group {
                        if let terminal = panes[index] {
                            BorrowedTerminalHost(terminal: terminal)
                        } else {
                            ContentUnavailableView {
                                Label("Shell ended", systemImage: "terminal")
                            } actions: {
                                Button("New Shell") { respawn(index) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                }
            }
        }
        .frame(width: width)
    }

    /// A separator with a grab area either side. The window's coordinates,
    /// as the handle itself moves with the edge it drags.
    private var handle: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(width: 7)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let before = widthBeforeDrag ?? width
                        widthBeforeDrag = before
                        width = min(max(before - drag.translation.width, Self.widths.lowerBound), Self.widths.upperBound)
                    }
                    .onEnded { _ in widthBeforeDrag = nil }
            )
    }
}
