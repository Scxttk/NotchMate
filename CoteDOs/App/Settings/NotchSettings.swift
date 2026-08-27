import SwiftUI

struct NotchSettings: View {
    @ObservedObject var settings: UserSettings

    var body: some View {
        Form {
            Section {
                ForEach(NotchViewModel.Tab.allCases, id: \.self) { tab in
                    Toggle(tab.title, isOn: tabBinding(tab))
                        // The last enabled tab can't be switched off — the
                        // notch always needs at least one page.
                        .disabled(settings.isTabEnabled(tab) && NotchViewModel.enabledTabs.count == 1)
                }
            } header: {
                Text(String(localized: "settings.tabs.header", defaultValue: "Tabs"))
            } footer: {
                Text(String(localized: "settings.tabs.hint", defaultValue: "Deaktivierte Tabs verschwinden aus der Notch. Mindestens ein Tab bleibt immer aktiv."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "settings.liveActivities", defaultValue: "Live Activities (Laden, Datei empfangen)"), isOn: $settings.liveActivitiesEnabled)
                Toggle(String(localized: "settings.audioRoute", defaultValue: "Audio-Ausgabe-Wechsel (AirPods, Lautsprecher)"), isOn: $settings.audioRouteActivityEnabled)
                    .disabled(!settings.liveActivitiesEnabled)
                Toggle(String(localized: "settings.hud", defaultValue: "HUD-Ersatz (Lautstärke/Helligkeit)"), isOn: $settings.hudEnabled)
                Toggle(String(localized: "settings.suppressOSD", defaultValue: "Lautstärke & Helligkeit nur in der Notch (Bedienungshilfen nötig)"), isOn: $settings.suppressSystemOSD)
                    .disabled(!settings.hudEnabled)
            } header: {
                Text(String(localized: "settings.notch.display", defaultValue: "Anzeige"))
            } footer: {
                Text(String(localized: "settings.audioRoute.hint", defaultValue: "macOS zeigt beim Verbinden von AirPods eine eigene Einblendung. Schalte den Ausgabe-Wechsel ab, wenn du sie nicht doppelt sehen willst."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Also in the status menu. Here as well because this is where you
            // look for it after dragging the island somewhere you regret, and
            // the status menu is the one surface a mis-placed notch can sit on
            // top of.
            Section {
                Button(String(localized: "settings.notch.resetPlacement", defaultValue: "Notch mittig nach oben")) {
                    NotificationCenter.default.post(name: .notchResetPlacement, object: nil)
                }
            } header: {
                Text(String(localized: "settings.notch.placement", defaultValue: "Position"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func tabBinding(_ tab: NotchViewModel.Tab) -> Binding<Bool> {
        Binding(
            get: { settings.isTabEnabled(tab) },
            set: { settings.setTab(tab, enabled: $0) }
        )
    }
}
