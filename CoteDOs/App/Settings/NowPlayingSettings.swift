import SwiftUI

struct NowPlayingSettings: View {
    @ObservedObject var settings: UserSettings

    var body: some View {
        Form {
            Picker(String(localized: "settings.mediaSource", defaultValue: "Quelle"), selection: $settings.mediaSource) {
                ForEach(UserSettings.MediaSource.allCases) { source in
                    Text(source.localizedName).tag(source)
                }
            }
            Text("settings.mediaSource.hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section {
                Toggle(String(localized: "settings.spectrum.pillOnly", defaultValue: "Nur Spektrum statt Cover"), isOn: $settings.pillSpectrumOnly)
                // One knob. Bar width and gap are fixed, so this only decides
                // how many bars there are and how far the pill grows; the
                // readout names the bar count because that is what changes.
                LabeledContent(String(localized: "settings.spectrum.pillWidth", defaultValue: "Breite")) {
                    Slider(
                        value: $settings.pillSpectrumWidth,
                        in: NotchLayout.pillSpectrumMinWidth...NotchLayout.pillSpectrumMaxWidth,
                        step: Double(NotchLayout.pillSpectrumBarPitch)
                    )
                    Text("\(NotchLayout.pillSpectrumBarCount(forWidth: settings.pillSpectrumWidth)) ▎")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!settings.pillSpectrumOnly)
            } header: {
                Text(String(localized: "settings.spectrum.header", defaultValue: "Sound-Spektrum"))
            } footer: {
                Text(String(localized: "settings.spectrum.hint", defaultValue: "„Nur Spektrum“ ersetzt das Mini-Cover in der eingeklappten Notch durch ein breiteres Spektrum mit mehr Balken — der Musik-Tab behält sein Cover. Die Farben der Balken kommen immer vom Album-Cover. Mit ⌥⌘S nimmt sich das Spektrum den ganzen Bildschirm und hält ihn wach; sobald du zurückkommst oder die Musik aus ist, sperrt der Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
