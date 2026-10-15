import SwiftUI

/// Transcription settings: speech model, language and audio. Grouped form content for a Settings tab.
struct TranscriptionSettingsView: View {
    @Bindable private var prefs = TranscriptionPreferences.shared
    private var store = ModelStore.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var confirmingDelete: ModelTier?

    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Speech model",
                            footer: "Downloads once from Hugging Face, then runs entirely on this Mac, even offline.") {
                ForEach(Array(ModelTier.allCases.enumerated()), id: \.element) { index, tier in
                    if index > 0 { RowDivider() }
                    ModelRow(tier: tier, isSelected: prefs.model == tier, isRecommended: tier == store.recommended,
                             isInUse: isInUse(tier)) {
                        prefs.model = tier
                    } delete: {
                        confirmingDelete = tier
                    }
                }
            }

            SettingsSection(title: "Language") {
                SettingsRow(title: "Spoken language") {
                    Picker("", selection: $prefs.language) {
                        Text("Detect automatically").tag("")
                        Divider()
                        ForEach(TranscriptionPreferences.languages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                RowDivider()
                SettingsRow(title: "Translate to English") {
                    DCToggle(isOn: $prefs.translate)
                }
            }

            SettingsSection(title: "Audio", footer: "System audio hears calls, meetings and videos. macOS asks the first time.") {
                SettingsRow(title: "Listen to") {
                    DCSegmented(selection: $prefs.source, options: AudioSource.allCases.map { ($0, $0.label) })
                }
                RowDivider()
                SettingsRow(title: "Microphone") {
                    Picker("", selection: $prefs.inputDeviceUID) {
                        Text("System default").tag("")
                        if !prefs.inputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == prefs.inputDeviceUID }) {
                            Text("Disconnected device").tag(prefs.inputDeviceUID)
                        }
                        if !devices.isEmpty { Divider() }
                        ForEach(devices) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!prefs.source.usesMicrophone)
                RowDivider()
                SettingsRow(title: "Keep transcript window on top") {
                    DCToggle(isOn: $prefs.floatsOnTop)
                }
            }
        }
        .onAppear {
            devices = AudioDevices.inputs()
            store.refresh()
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                guard let tier = confirmingDelete else { return }
                Task { await store.delete(tier) }
            }
        } message: {
            Text("You can download it again at any time.")
        }
    }

    private var deleteTitle: String {
        guard let tier = confirmingDelete else { return "" }
        return "Delete the \(tier.title) model (\(ModelTier.size(store.build(for: tier).bytes)))?"
    }

    private func isInUse(_ tier: ModelTier) -> Bool {
        let controller = TranscriptionController.shared
        return controller.isBusy && prefs.model == tier
    }
}

private struct ModelRow: View {
    let tier: ModelTier
    let isSelected: Bool
    let isRecommended: Bool
    let isInUse: Bool
    let select: () -> Void
    let delete: () -> Void
    private var store = ModelStore.shared

    init(tier: ModelTier, isSelected: Bool, isRecommended: Bool, isInUse: Bool,
         select: @escaping () -> Void, delete: @escaping () -> Void) {
        self.tier = tier
        self.isSelected = isSelected
        self.isRecommended = isRecommended
        self.isInUse = isInUse
        self.select = select
        self.delete = delete
    }

    @Environment(\.settingsTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? theme.accent : theme.ink.opacity(0.25))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isRecommended ? "\(tier.title)  ·  Recommended" : tier.title)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.ink.opacity(0.88))
                        Text("\(tier.modelName) · \(ModelTier.size(store.build(for: tier).bytes))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.ink.opacity(0.42))
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Use This Model", select)
    }

    @ViewBuilder private var trailing: some View {
        switch store.phase(tier) {
        case .downloading(let fraction):
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.ink.opacity(0.1))
                        Capsule().fill(theme.accent).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(width: 80, height: 3)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.ink.opacity(0.45))
                    .frame(width: 32, alignment: .trailing)
                DCButton(title: "Cancel") { store.cancelDownload(tier) }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.ink.opacity(0.45))
                    .help(message)
                DCButton(title: "Retry") { store.download(tier) }
            }
        case .idle:
            if store.isInstalled(tier) {
                DCButton(title: "Delete…", destructive: true, action: delete)
                    .disabled(isInUse)
                    .opacity(isInUse ? 0.4 : 1)
            } else {
                DCButton(title: "Download") { store.download(tier) }
            }
        }
    }
}
