import SwiftUI

/// A tab's glyph.
struct TabIcon: View {
    let tab: NotchViewModel.Tab

    var body: some View {
        Image(systemName: tab.icon)
            // Its own size, not the surrounding font's. Inheriting the label's
            // 13 pt is what made these read as tiny: an SF Symbol set at text
            // size next to that text is always the smaller-looking of the two.
            .font(.system(size: NotchLayout.tabIconSize, weight: .medium))
    }
}

/// The row of tabs across the top of the expanded island.
///
/// Icons only, no titles, and that is what buys the icons their size. Five
/// German titles come to ~472 pt against the 348 pt the band capsule offers, so
/// a labelled row has to be scaled to ~0.72 to fit — which shrinks the icons
/// along with the text and lands them at about 9 pt. Dropping the titles takes
/// the row to ~210 pt, no scaling at all, and leaves room to draw the glyphs
/// half again as large.
///
/// What the titles were doing, selection now does: the chosen tab sits in a
/// filled capsule, the way a segmented control marks its selection. The names
/// are still reachable — tooltip on hover, and VoiceOver reads them, which it
/// could not do before because the visible text *was* the accessible name.
struct NotchTabBar: View {
    @Binding var selection: NotchViewModel.Tab
    /// When false (`.solo`/`.condensing`), only the selected tab is present —
    /// the others have left the layout, letting the capsule narrow onto it.
    let showsAllTabs: Bool
    /// Whether the island is resting open. `.band` shows every tab too, but at
    /// pill height on the way past — a row that is about to be a pill, not an
    /// interface. Only an open island is wide and tall enough to dress.
    let isOpen: Bool
    /// The border the island is on. The strip runs along it — a row at the top
    /// or bottom, a column standing against a side — and every slot turns with
    /// it. The glyphs themselves never rotate: a sideways `radio.fill` reads as
    /// a rendering fault, not as a vertical tab bar.
    var dock: NotchDock = .top
    /// Observed so the bar re-renders live when tabs are toggled in Settings.
    @ObservedObject private var settings = UserSettings.shared
    /// Ties the one selection capsule to whichever tab's slot it is standing in.
    @Namespace private var selectionGeometry

    var body: some View {
        AxisStack(axis: dock.isHorizontal ? .horizontal : .vertical,
                  spacing: NotchLayout.tabBarSpacing) {
            ForEach(NotchViewModel.enabledTabs, id: \.self) { value in
                tab(value)
            }
        }
        // The row travels on its own clock, not the capsule's: shedding the
        // other tabs re-centres the surviving glyph, and that move is what the
        // pill handover waits for. See `NotchLayout.tabCondenseAnimation`.
        .animation(NotchLayout.tabCondenseAnimation, value: showsAllTabs)
        .background {
            // One capsule for the row, borrowing the selected tab's slot —
            // not a capsule per tab. Per-tab capsules can only ever cross-fade,
            // one dimming while another lights up two slots over, and the eye
            // reads that as a blink rather than as a move. A single view
            // adopting the new slot's frame slides between them, which is what
            // a segmented control does everywhere else on the system.
            //
            // Behind the whole row rather than behind one item, so it is free
            // to travel across the gaps between them.
            if isOpen {
                Capsule(style: .continuous)
                    .fill(.white.opacity(NotchLayout.tabSelectionFill))
                    .matchedGeometryEffect(id: selection, in: selectionGeometry, isSource: false)
                    // Its own, because not every way of changing tabs animates:
                    // the capture hotkey sets the tab outright, and the capsule
                    // should still slide when it does.
                    .animation(NotchLayout.tabChangeAnimation, value: selection)
            }
        }
    }

    @ViewBuilder
    private func tab(_ value: NotchViewModel.Tab) -> some View {
        if showsAllTabs || selection == value {
            let isSelected = selection == value
            Button {
                guard selection != value else { return }
                Haptics.perform(.alignment)
                withAnimation(NotchLayout.tabChangeAnimation) { selection = value }
            } label: {
                // Every icon renders itself, always — switching tabs must only
                // change the highlight, never replace or move the icon view, or
                // it visibly pops back in.
                let slot = NotchLayout.tabItemSize(on: dock)
                TabIcon(tab: value)
                    .frame(width: slot.width, height: slot.height)
                    // Publishes this slot for the capsule to borrow. Every item
                    // holds the same frame, selected or not, so the capsule
                    // arriving cannot move the row it is arriving in.
                    .matchedGeometryEffect(id: value, in: selectionGeometry, isSource: true)
                    .foregroundStyle(.white.opacity(isSelected ? 1 : NotchLayout.tabInactiveOpacity))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(value.title)
            .accessibilityLabel(value.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            // Insertion waits for the selected icon's flight to its slot to
            // finish (it crosses the other tabs' positions on the way);
            // removal on collapse stays immediate — the capsule narrows fast
            // and lingering neighbours would get clipped against its rim.
            .transition(.asymmetric(
                insertion: .opacity.animation(
                    NotchLayout.condenseFadeAnimation.delay(NotchLayout.tabJoinFadeDelay)),
                removal: .opacity.animation(NotchLayout.condenseFadeAnimation)
            ))
        }
    }
}
