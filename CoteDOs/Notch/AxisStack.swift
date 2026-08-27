import SwiftUI

/// An `HStack` or a `VStack`, chosen at runtime.
///
/// The island lays its parts out *along* whichever border it is parked on, so
/// the tab strip, the pill's contents and the page carousel all need the same
/// stack in two directions. SwiftUI has no built-in for that, and writing the
/// branch at each call site duplicates the spacing and alignment arguments
/// three ways.
///
/// Switching `axis` re-mounts the content — the two stacks are different view
/// types, so nothing inside them keeps its identity across the change. That is
/// acceptable exactly once: the axis only ever changes when the island is
/// carried to a border on the other axis, which is already a full re-layout.
struct AxisStack<Content: View>: View {
    let axis: Axis
    var spacing: CGFloat = 0
    /// Cross-axis alignment, named for the axis-free case: "centre the parts
    /// across the direction they are stacked in".
    var alignment: Alignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch axis {
        case .horizontal:
            HStack(alignment: alignment.vertical, spacing: spacing) { content() }
        case .vertical:
            VStack(alignment: alignment.horizontal, spacing: spacing) { content() }
        }
    }
}

/// Lay a wide little segment along a *vertical* pill by turning it a quarter
/// turn, and claim the transposed space for it.
///
/// For the parts of the pill that are text: a focus readout is ~45 pt wide and
/// a side-docked capsule is 30 pt thick, so upright it would be clipped to
/// "24:" by the silhouette. Glyphs are never treated this way — a sideways
/// `radio.fill` reads as a bug — but a readout turned to run with the border
/// reads the way a vertical tab label does, and it keeps the pill's own
/// thickness constant, which is what the length estimate in
/// `NotchViewModel.collapsedWidth` assumes.
///
/// `rotationEffect` does not change layout, so the frame has to be transposed
/// by hand; `length` is the segment's own upright width.
struct AlongBorder: ViewModifier {
    let vertical: Bool
    let length: CGFloat
    let thickness: CGFloat

    func body(content: Content) -> some View {
        if vertical {
            content
                .fixedSize()
                .frame(width: length, height: thickness)
                // Counter-clockwise, so it reads bottom-to-top — the direction
                // macOS turns vertical text in (a rotated window title, a chart
                // axis label).
                .rotationEffect(.degrees(-90))
                .frame(width: thickness, height: length)
        } else {
            content
        }
    }
}
