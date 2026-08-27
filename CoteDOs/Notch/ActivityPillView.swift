import SwiftUI

/// Compact rendering of a live activity inside the collapsed pill.
struct ActivityCompactView: View {
    let activity: NotchActivity
    /// The border the pill is on. On a side one the activity loses its words —
    /// see `NotchLayout.activityLength(isRoute:hasProgress:on:)`.
    var dock: NotchDock = .top

    private var isRoute: Bool { activity.kind == .audioRoute }
    private var isVertical: Bool { !dock.isHorizontal }

    var body: some View {
        AxisStack(axis: isVertical ? .vertical : .horizontal, spacing: 8) {
            Image(systemName: activity.icon)
                // The audio-route icon is bumped up so a connecting device reads
                // clearly at a glance (the main "markant" ask).
                .font(.system(size: isRoute ? 17 : 12, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: isRoute ? 22 : 16)
            if let progress = activity.progress {
                let fraction = CGFloat(min(max(progress, 0), 1))
                GeometryReader { geo in
                    // Fills from the border end on a vertical pill, the same way
                    // it fills from the leading edge on a horizontal one.
                    ZStack(alignment: isVertical ? .top : .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: isVertical ? nil : geo.size.width * fraction,
                                   height: isVertical ? geo.size.height * fraction : nil)
                    }
                }
                .frame(width: isVertical ? 4 : nil, height: isVertical ? nil : 4)
            } else if !isVertical {
                Text(activity.title)
                    .font(.system(size: isRoute ? 12 : 11, weight: isRoute ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let detail = activity.detail {
                    BatteryBadge(text: detail)
                }
            }
        }
        .padding(isVertical ? .vertical : .horizontal, isRoute ? 12 : 14)
        // Same fixed band against the border as CollapsedView, so activity
        // content doesn't drift across the island while it morphs.
        .frame(width: isVertical ? NotchLayout.currentCollapsedHeight : nil,
               height: isVertical ? nil : NotchLayout.currentCollapsedHeight)
        .frame(maxWidth: isVertical ? .infinity : nil,
               maxHeight: isVertical ? nil : .infinity,
               alignment: bandAlignment)
    }

    private var bandAlignment: Alignment {
        switch dock {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

/// A small tinted battery pill (icon + percentage), tinted red/orange when low.
struct BatteryBadge: View {
    let text: String

    private var level: Int? { Int(text.replacingOccurrences(of: "%", with: "")) }

    private var color: Color {
        switch level ?? 100 {
        case ..<15: return .red
        case ..<30: return .orange
        default: return .green
        }
    }

    private var symbol: String {
        switch level ?? 100 {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
    }
}
