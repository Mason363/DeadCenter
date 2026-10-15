import SwiftUI

struct ReadingSettingsView: View {
    @Bindable private var prefs = Preferences.shared
    @State private var lastImageDuration = 10.0
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Speed") {
                SettingsRow(title: "Words per minute") {
                    HStack(spacing: 12) {
                        DCSlider(value: Binding(get: { Double(prefs.wpm) }, set: { prefs.wpm = Int($0) }),
                                 range: Double(Preferences.wpmRange.lowerBound)...Double(Preferences.wpmRange.upperBound),
                                 step: 25, width: 170)
                        Text("\(prefs.wpm)")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(theme.ink.opacity(0.85))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                RowDivider()
                SettingsRow(title: "Adaptive speed", detail: "More time for dense passages. Never faster than your speed.") {
                    DCToggle(isOn: $prefs.adaptiveSpeed)
                }
            }

            SettingsSection(title: "Rhythm") {
                SettingsRow(title: "Focus letter", detail: pivotHint) {
                    DCSegmented(selection: $prefs.pivotMode,
                                options: PivotMode.allCases.map { ($0, $0 == .optimal ? "Optimal" : "Middle") })
                }
                RowDivider()
                SettingsRow(title: "Bare words", detail: "Hide brackets, quotes and dashes around words. The pauses stay.") {
                    DCToggle(isOn: $prefs.bareWords)
                }
                RowDivider()
                SettingsRow(title: "Pacing", detail: pacingHint) {
                    DCSegmented(selection: $prefs.pacing, options: Pacing.allCases.map { ($0, $0.label) })
                }
                RowDivider()
                SettingsRow(title: "Ease in") {
                    DCToggle(isOn: $prefs.easeIn)
                }
                RowDivider()
                SettingsRow(title: "Resume from sentence start") {
                    DCToggle(isOn: $prefs.resumeAtSentence)
                }
            }

            SettingsSection(title: "Images") {
                SettingsRow(title: "Show images") {
                    DCToggle(isOn: $prefs.showImages)
                }
                RowDivider()
                SettingsRow(title: "Show each image for") {
                    HStack(spacing: 12) {
                        DCSlider(value: Binding(
                            get: { waits ? lastImageDuration : prefs.imageDuration },
                            set: { prefs.imageDuration = $0; lastImageDuration = $0 }),
                                 range: 1...15, step: 1, width: 150)
                            .disabled(waits)
                            .opacity(waits ? 0.4 : 1)
                        Text(waits ? "—" : "\(Int(prefs.imageDuration)) s")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(theme.ink.opacity(0.85))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!prefs.showImages)
                RowDivider()
                SettingsRow(title: "Until I continue") {
                    DCToggle(isOn: Binding(get: { waits }, set: { prefs.imageDuration = $0 ? 0 : lastImageDuration }))
                }
                .disabled(!prefs.showImages)
            }
        }
        .onAppear {
            if prefs.imageDuration > 0 { lastImageDuration = prefs.imageDuration }
        }
    }

    private var waits: Bool { prefs.imageDuration == 0 }

    private var pivotHint: String {
        switch prefs.pivotMode {
        case .optimal: "About a third of the way in, where your eye lands naturally."
        case .middle: "The exact middle of each word."
        }
    }

    private var pacingHint: String {
        switch prefs.pacing {
        case .even: "Every word gets the same time."
        case .natural: "Short pauses at punctuation and long words."
        case .relaxed: "Longer pauses, for a calmer rhythm."
        }
    }
}
