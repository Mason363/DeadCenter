import SwiftUI
import UniformTypeIdentifiers

/// The transcript window's content: the text, a first-run or idle hint, and a quiet control bar.
struct TranscriptView: View {
    let controller: TranscriptionController

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    @State private var following = true
    @State private var jumpRequest = 0
    @State private var dropTargeted = false

    private var prefs = Preferences.shared
    private var settings = TranscriptionPreferences.shared
    private var store = ModelStore.shared

    init(controller: TranscriptionController) {
        self.controller = controller
    }

    var body: some View {
        let palette = prefs.palette(systemIsDark: colorScheme == .dark)
        let transcript = controller.transcript
        let ink = Color(nsColor: palette.text)
        let accent = Color(nsColor: palette.pivot)

        ZStack(alignment: .bottom) {
            TranscriptTextView(
                segments: transcript.segments,
                tentative: transcript.tentative,
                generation: transcript.generation,
                style: TranscriptStyle(text: palette.text, font: prefs.font(size: (22 * prefs.textScale).rounded())),
                following: $following,
                jumpRequest: jumpRequest)

            if transcript.isEmpty {
                EmptyState(controller: controller, ink: ink, accent: accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                if !following && !transcript.isEmpty {
                    Button {
                        following = true
                        jumpRequest += 1
                    } label: {
                        Label(controller.isLive ? "Jump to live" : "Jump to end", systemImage: "arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(ink.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ink.opacity(0.8))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let notice = controller.notice {
                    NoticeLine(notice: notice, ink: ink) { controller.dismissNotice() }
                        .transition(.opacity)
                }
                if store.isInstalled(settings.model) || controller.isBusy || !transcript.isEmpty {
                    ControlBar(controller: controller, expanded: hovering || !controller.isBusy, ink: ink, accent: accent)
                }
            }
            .padding(.bottom, 10)
            .background(alignment: .bottom) {
                LinearGradient(colors: [Color(nsColor: palette.background).opacity(0), Color(nsColor: palette.background)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55))
                    .frame(height: 96)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            // Text fades out under the title bar.
            LinearGradient(colors: [Color(nsColor: palette.background), Color(nsColor: palette.background).opacity(0)],
                           startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
                .frame(height: 52)
                .allowsHitTesting(false)
        }
        .background(Color(nsColor: palette.background))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accent.opacity(0.7), lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .environment(\.settingsTheme, SettingsTheme(palette))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.easeOut(duration: 0.2), value: following)
        .animation(.easeOut(duration: 0.2), value: controller.notice)
        .animation(.easeOut(duration: 0.2), value: transcript.isEmpty)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in controller.transcribe(file: url) }
            }
            return true
        }
        .onChange(of: settings.model) { controller.prepareModel() }
        .onChange(of: store.installed) { controller.prepareModel() }
        .onChange(of: transcript.generation) {
            following = true
            jumpRequest += 1
        }
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    let controller: TranscriptionController
    let ink: Color
    let accent: Color
    private var store = ModelStore.shared
    private var settings = TranscriptionPreferences.shared

    init(controller: TranscriptionController, ink: Color, accent: Color) {
        self.controller = controller
        self.ink = ink
        self.accent = accent
    }

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(ink.opacity(0.85))
    }

    @ViewBuilder private var content: some View {
        let tier = settings.model
        if !store.isInstalled(tier) {
            Text("Transcribe meetings, lectures and recordings, privately on this Mac.")
                .font(.title3)
            switch store.phase(tier) {
            case .idle:
                Button {
                    store.download(tier)
                } label: {
                    Text("Download Speech Model (\(ModelTier.size(store.build(for: tier).bytes)))")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                Text("\(tier.modelName), from Hugging Face. Change it in Settings.")
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.5))
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .tint(accent)
                    .frame(width: 260)
                HStack(spacing: 12) {
                    Text("Downloading… \(Int(fraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(ink.opacity(0.55))
                    Button("Cancel") { store.cancelDownload(tier) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.6))
                Button("Try Again") { store.download(tier) }
                    .controlSize(.large)
            }
        } else {
            switch controller.activity {
            case .idle, .starting:
                switch controller.modelPhase {
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(ink.opacity(0.6))
                default:
                    Text("Press Space to start listening")
                        .font(.title3)
                        .foregroundStyle(ink.opacity(0.6))
                    Text("or drop a recording or video here")
                        .font(.callout)
                        .foregroundStyle(ink.opacity(0.4))
                }
            case .live, .finishing:
                Text("Listening…")
                    .font(.title3)
                    .foregroundStyle(ink.opacity(0.45))
            case .file(let name, _):
                Text("Transcribing “\(name)”…")
                    .font(.title3)
                    .foregroundStyle(ink.opacity(0.45))
            }
        }
    }
}

// MARK: - Notice

private struct NoticeLine: View {
    let notice: TranscriptionController.Notice
    let ink: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(notice.text)
                .lineLimit(2)
            if let action = notice.action, let url = notice.url {
                Button(action) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink.opacity(0.45))
            .help("Dismiss")
        }
        .font(.callout)
        .foregroundStyle(ink.opacity(0.75))
        .padding(.horizontal, 20)
    }
}

// MARK: - Control bar

private struct ControlBar: View {
    let controller: TranscriptionController
    let expanded: Bool
    let ink: Color
    let accent: Color

    @Bindable private var settings = TranscriptionPreferences.shared
    @State private var copied = false

    init(controller: TranscriptionController, expanded: Bool, ink: Color, accent: Color) {
        self.controller = controller
        self.expanded = expanded
        self.ink = ink
        self.accent = accent
    }

    var body: some View {
        HStack(spacing: 14) {
            RecordButton(controller: controller, accent: accent, ink: ink)

            if case .file(_, let progress) = controller.activity {
                ProgressView(value: progress)
                    .tint(accent)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.55))
            } else {
                if expanded {
                    DCSegmented(selection: $settings.source, options: AudioSource.allCases.map { ($0, $0.label) })
                        .disabled(controller.isBusy)
                        .opacity(controller.isBusy ? 0.45 : 1)
                    .help(controller.isBusy ? "Stop to change what Dead Center listens to" : "What to listen to")
                }
                Clock(controller: controller)
                    .foregroundStyle(ink.opacity(0.5))
            }

            Spacer(minLength: 8)

            if expanded && !controller.transcript.isEmpty { actions }
            if expanded || controller.followsInReader { followToggle }
            if expanded { moreMenu }
        }
        .font(.system(size: 12))
        .frame(height: 28)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var actions: some View {
        BarButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy transcript (⌘C)", ink: ink) {
            controller.copyAll()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        }
        BarButton(symbol: "square.and.arrow.down", help: "Save as text, Markdown or subtitles (⌘S)", ink: ink) {
            controller.save()
        }
        BarButton(symbol: "eyeglasses", help: "Read in Dead Center", ink: ink) {
            controller.readInDeadCenter()
        }
    }

    private var followToggle: some View {
        BarButton(symbol: "dot.radiowaves.forward",
                  help: controller.followsInReader ? "Stop following live in the reader" : "Follow live in the reader",
                  ink: controller.followsInReader ? accent : ink, emphasized: controller.followsInReader) {
            controller.followsInReader.toggle()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Transcribe a File…") { controller.presentOpenPanel() }
            Button("New Transcript") { controller.newTranscript() }
                .disabled(controller.isBusy || controller.transcript.isEmpty)
            Divider()
            Toggle("Keep on Top", isOn: $settings.floatsOnTop)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(ink.opacity(0.6))
        .help("More")
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let ink: Color
    var emphasized = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink.opacity(emphasized || hovering ? 0.95 : 0.6))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Red dot: tap to start, tap again to stop. Pulses while listening.
private struct RecordButton: View {
    let controller: TranscriptionController
    let accent: Color
    let ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let live = controller.activity == .live
        let waiting = controller.activity == .starting || controller.activity == .finishing
        Button {
            controller.toggleRecording()
        } label: {
            ZStack {
                if live {
                    Circle()
                        .stroke(accent.opacity(reduceMotion ? 0.5 : (pulse ? 0 : 0.6)), lineWidth: 2)
                        .frame(width: 13, height: 13)
                        .scaleEffect(reduceMotion ? 1.45 : (pulse ? 2 : 1))
                }
                Circle()
                    .fill(accent)
                    .frame(width: 13, height: 13)
                    .opacity(waiting ? 0.4 : 1)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(waiting || isFile)
        .help(live ? "Stop listening (Space)" : "Start listening (Space)")
        .accessibilityLabel(live ? "Stop listening" : "Start listening")
        .onChange(of: live, initial: true) { _, isLive in
            pulse = false
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var isFile: Bool {
        if case .file = controller.activity { true } else { false }
    }
}

/// Elapsed listening time, or the transcript's length when stopped.
private struct Clock: View {
    let controller: TranscriptionController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = controller.clockBase + (controller.liveSince.map { context.date.timeIntervalSince($0) } ?? 0)
            if elapsed > 0 || controller.isLive {
                Text(Transcript.clock(elapsed))
                    .monospacedDigit()
            }
        }
    }
}
