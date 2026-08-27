import CoreGraphics

/// The screen border the island is parked on. It is always on one: the panel is
/// dragged freely and lands on the nearest edge when the button comes up, so it
/// can be moved out of the way of whatever it covers without ever ending up
/// adrift in the middle of the screen.
enum NotchDock: String, CaseIterable {
    case top
    case bottom
    case leading
    case trailing

    /// Whether the island slides left/right along this edge (as opposed to
    /// up/down along a side one). Also the island's own long direction: on a
    /// side border the whole thing stands up, tab column and spectrum with it.
    var isHorizontal: Bool { self == .top || self == .bottom }

    /// Whether the tab band comes first in layout order.
    ///
    /// The band always hugs the docked border — it is the part the collapsed
    /// pill hands over to, so it has to sit exactly where the pill was. That
    /// puts it first on the top and leading borders and last on the bottom and
    /// trailing ones, which is what makes the island a mirror of itself rather
    /// than the same layout slid somewhere else.
    var bandLeads: Bool { self == .top || self == .leading }

    /// Compose a size from a length *along* this border and a thickness
    /// *away* from it. The island's two dimensions are named this way
    /// everywhere, so one formula serves all four borders.
    func size(length: CGFloat, thickness: CGFloat) -> CGSize {
        isHorizontal ? CGSize(width: length, height: thickness)
                     : CGSize(width: thickness, height: length)
    }

    /// Read a size back as its length along this border and thickness away
    /// from it — the inverse of `size(length:thickness:)`.
    func lengthAndThickness(of size: CGSize) -> (length: CGFloat, thickness: CGFloat) {
        isHorizontal ? (size.width, size.height) : (size.height, size.width)
    }

    /// The scroll component that opens the island here: positive pulls it out
    /// of its border, negative pushes it back. Mirrored per border so the
    /// gesture always means the same thing physically — swipe down off the top
    /// edge, up off the bottom one, right off the left one.
    func openingAmount(dx: CGFloat, dy: CGFloat) -> CGFloat {
        switch self {
        case .top:      return dy
        case .bottom:   return -dy
        case .leading:  return dx
        case .trailing: return -dx
        }
    }

    /// The scroll component that pages between tabs: across the island's long
    /// direction, which is the direction the tab strip itself runs.
    func pagingAmount(dx: CGFloat, dy: CGFloat) -> CGFloat {
        isHorizontal ? dx : dy
    }

    /// Grow a rect outward past this edge.
    ///
    /// The cursor's coordinate when it is shoved against a screen border equals
    /// the screen's own bound, and `CGRect.contains` treats the max edges as
    /// exclusive — without the bleed the notch refuses to open at exactly the
    /// place it lives.
    func bleeding(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        switch self {
        case .top:      return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + amount)
        case .bottom:   return CGRect(x: rect.minX, y: rect.minY - amount, width: rect.width, height: rect.height + amount)
        case .leading:  return CGRect(x: rect.minX - amount, y: rect.minY, width: rect.width + amount, height: rect.height)
        case .trailing: return CGRect(x: rect.minX, y: rect.minY, width: rect.width + amount, height: rect.height)
        }
    }
}

/// Where the user has parked the island: an edge, plus how far along that edge
/// it sits — measured from the edge's centre, positive meaning right on a
/// horizontal edge and down on a vertical one.
///
/// `home` is the physical notch's own place, and it is more than one placement
/// among five: the automatic placements (the Safari-fullscreen dodge, the
/// menu-bar overlap hide) and the pill's hero centring all exist to make *that*
/// pose behave, and they stand down as soon as the user has put the island
/// somewhere themselves.
///
/// All geometry here is pure and screen-coordinate based (origin bottom-left,
/// AppKit style), so `NotchWindowController`'s hit and hover rects, the
/// container view's local rect and the panel's own frame all derive from one
/// implementation instead of three that must agree.
struct NotchPlacement: Equatable {

    /// Where along the border the island sits.
    ///
    /// A corner is not just "`along` at its limit". The island is centred in
    /// its panel, and the panel carries a margin at each end for the shadow —
    /// so a panel shoved as far as it goes still leaves the *island* some 30 pt
    /// short of the corner, and a collapsed pill (which is much shorter than
    /// the panel it is centred in) hundreds of points short. A corner
    /// placement therefore pins the island to that end of the panel and lets
    /// the panel's shadow margin hang off the screen, which is what puts the
    /// island itself in the corner.
    enum Anchor: String, CaseIterable {
        case start
        case centre
        case end

        var isCorner: Bool { self != .centre }
    }

    var dock: NotchDock = .top
    var anchor: Anchor = .centre
    /// Distance from the centre of the border, positive meaning right or down.
    /// Only meaningful while `anchor` is `.centre`; a corner has no slack.
    var along: CGFloat = 0

    static let home = NotchPlacement()

    var isHome: Bool { self == .home }

    // MARK: Geometry

    /// The panel's frame for this placement. The panel keeps its fixed size and
    /// hugs the docked edge; `dodge` is the Safari-dodge shift (x right, y
    /// down), which only ever applies at `home`.
    ///
    /// A corner shoves the panel as far along the border as it goes; the
    /// island, pinned to that end of it, then sits `gap` from the corner. Its
    /// shadow on that side is clipped by the panel edge, exactly as the top
    /// border already clips the shadow above the island.
    func panelFrame(screen: CGRect, panelSize: CGSize, dodge: CGSize = .zero) -> CGRect {
        let (screenLength, panelLength) = dock.isHorizontal
            ? (screen.width, panelSize.width)
            : (screen.height, panelSize.height)
        // Distance from the border's centre to the panel's centre.
        let offset: CGFloat
        switch anchor {
        case .start:  offset = -(screenLength - panelLength) / 2
        case .end:    offset = (screenLength - panelLength) / 2
        case .centre: offset = along
        }
        let origin: CGPoint
        switch dock {
        case .top:
            origin = CGPoint(x: screen.midX - panelSize.width / 2 + offset,
                             y: screen.maxY - panelSize.height)
        case .bottom:
            origin = CGPoint(x: screen.midX - panelSize.width / 2 + offset,
                             y: screen.minY)
        case .leading:
            origin = CGPoint(x: screen.minX,
                             y: screen.midY - panelSize.height / 2 - offset)
        case .trailing:
            origin = CGPoint(x: screen.maxX - panelSize.width,
                             y: screen.midY - panelSize.height / 2 - offset)
        }
        return CGRect(x: origin.x + dodge.width, y: origin.y - dodge.height,
                      width: panelSize.width, height: panelSize.height)
    }

    /// The island's rect inside a panel rect — the AppKit mirror of how
    /// `NotchRootView` aligns the island, so the rects that react to the cursor
    /// can't drift from what is drawn. `gap` is the sliver the island floats off
    /// its border; `shift` moves the capsule along the edge (the pill's hero
    /// centring, which only applies at `home`).
    ///
    /// The island is pinned to the docked edge and free at the opposite one:
    /// that is what makes it grow *inward* when it expands, instead of off the
    /// screen it is glued to.
    func islandRect(inPanel panel: CGRect, size: CGSize, gap: CGFloat, shift: CGFloat = 0) -> CGRect {
        // Along the border the island is centred in its panel — except in a
        // corner, where it is pinned to that end of it. Pinning is the whole
        // mechanism: the panel is much longer than a collapsed pill, so a
        // centred pill can never reach a corner however far the panel goes.
        func alongPosition(min: CGFloat, max: CGFloat, extent: CGFloat) -> CGFloat {
            switch anchor {
            case .start:  return min + gap
            case .end:    return max - gap - extent
            case .centre: return (min + max) / 2 - extent / 2 + shift
            }
        }
        let x: CGFloat
        let y: CGFloat
        switch dock {
        case .top, .bottom:
            x = alongPosition(min: panel.minX, max: panel.maxX, extent: size.width)
            y = dock == .top ? panel.maxY - gap - size.height : panel.minY + gap
        case .leading, .trailing:
            x = dock == .leading ? panel.minX + gap : panel.maxX - gap - size.width
            // A vertical border runs downward, so `.start` is its top end —
            // the high y in AppKit's coordinates.
            y = anchor == .start ? panel.maxY - gap - size.height
              : anchor == .end ? panel.minY + gap
              : panel.midY - size.height / 2
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Landing

    /// Where a freely dragged panel lands: the nearest border, at the position
    /// along it the drag ended on.
    ///
    /// Distance is measured from the *island*, not the panel — the panel is
    /// mostly shadow margin, so an island resting 2 pt below the top edge would
    /// otherwise read as nearer to whichever side edge its margin reached first.
    /// `panelSize` is asked for the border that wins, not given outright: the
    /// island turns when it lands on a side one, so the panel it has to be
    /// clamped inside is a different shape from the one that was dragged.
    static func snapping(islandRect: CGRect, screen: CGRect,
                         panelSize: (NotchDock) -> CGSize,
                         centreSnap: CGFloat, cornerSnap: CGFloat) -> NotchPlacement {
        let distances: [(dock: NotchDock, distance: CGFloat)] = [
            (.top, screen.maxY - islandRect.maxY),
            (.bottom, islandRect.minY - screen.minY),
            (.leading, islandRect.minX - screen.minX),
            (.trailing, screen.maxX - islandRect.maxX),
        ]
        let dock = distances.min { $0.distance < $1.distance }?.dock ?? .top
        // How far each end of the island is from the matching end of the
        // border. Measured on the island, not the panel, so a corner means the
        // thing you can see is in the corner.
        let (toStart, toEnd) = dock.isHorizontal
            ? (islandRect.minX - screen.minX, screen.maxX - islandRect.maxX)
            : (screen.maxY - islandRect.maxY, islandRect.minY - screen.minY)
        if toStart < cornerSnap, toStart <= toEnd { return NotchPlacement(dock: dock, anchor: .start) }
        if toEnd < cornerSnap { return NotchPlacement(dock: dock, anchor: .end) }

        let raw = dock.isHorizontal ? islandRect.midX - screen.midX : screen.midY - islandRect.midY
        return NotchPlacement(dock: dock, anchor: .centre,
                              along: clamped(along: raw, dock: dock, screen: screen,
                                             panelSize: panelSize(dock), centreSnap: centreSnap))
    }

    /// Keep the panel on the screen it is docked to, and make the border's
    /// centre sticky: within `centreSnap` the island lands exactly centred, so
    /// the notch's home pose — and the automatic placements that depend on it —
    /// is easy to get back to by hand.
    static func clamped(along: CGFloat, dock: NotchDock, screen: CGRect,
                        panelSize: CGSize, centreSnap: CGFloat) -> CGFloat {
        let travel = dock.isHorizontal
            ? (screen.width - panelSize.width) / 2
            : (screen.height - panelSize.height) / 2
        guard travel > 0 else { return 0 }
        let snapped = abs(along) < centreSnap ? 0 : along
        return min(max(snapped, -travel), travel)
    }
}
