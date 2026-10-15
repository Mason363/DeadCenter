import Combine
import KeyboardShortcuts
import SwiftUI

/// Three quiet steps: read a sentence, allow Accessibility, learn the shortcut.
struct OnboardingView: View {
    var onFinish: () -> Void
    var onAccessGranted: () -> Void

    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var accessibility = AccessibilityAccess.shared

    init(onFinish: @escaping () -> Void, onAccessGranted: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onAccessGranted = onAccessGranted
    }

    static let welcomeText = "Welcome to Dead Center. Words come to you one at a time. Keep your eyes on the red letter. That's it."

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: WelcomeStep().transition(stepTransition)
                case 1: AccessStep(onGranted: onAccessGranted).transition(stepTransition)
                default: ShortcutStep().transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 20) {
                buttons
                    .frame(height: 36)
                PageIndicator(count: 3, current: step)
            }
        }
        .padding(.top, 44)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var buttons: some View {
        switch step {
        case 0:
            Button("Continue", action: advance)
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        case 1 where !accessibility.isTrusted:
            HStack(spacing: 10) {
                Button("Skip", action: advance)
                    .buttonStyle(OnboardingButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") { accessibility.request() }
                    .buttonStyle(OnboardingButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        case 1:
            Button("Continue", action: advance)
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        default:
            Button("Start Reading", action: onFinish)
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func advance() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.86)) {
            step = min(step + 1, 2)
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 48).combined(with: .opacity),
            removal: .offset(x: -48).combined(with: .opacity))
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            ReticleMark()
            Spacer(minLength: 0)
            ReaderPreview(text: OnboardingView.welcomeText, loops: true)
                .frame(width: 560, height: 150)
            Text("Dead Center lives in your menu bar.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
    }
}

private struct AccessStep: View {
    var onGranted: () -> Void
    private var accessibility = AccessibilityAccess.shared
    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
    }

    var body: some View {
        let granted = accessibility.isTrusted
        VStack(spacing: 0) {
            AccessBadge(granted: granted)
                .padding(.bottom, 26)
            Text(granted ? "You're all set" : "Read what you select")
                .font(.system(size: 24, weight: .semibold))
                .contentTransition(.opacity)
                .padding(.bottom, 10)
            Text("Dead Center uses Accessibility to read the text you select in any app. What you read never leaves your Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)
            Text("You can skip this. The shortcut will read your clipboard instead.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.32))
                .padding(.top, 14)
                .opacity(granted ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.3), value: granted)
        .onReceive(poll) { _ in accessibility.refresh() }
        .onChange(of: granted) { _, nowGranted in
            if nowGranted { onGranted() }
        }
    }
}

private struct ShortcutStep: View {
    @State private var keys: [KeycapLabel] = KeycapLabel.labels(for: KeyboardShortcuts.getShortcut(for: .read))

    var body: some View {
        VStack(spacing: 0) {
            Text("Select text anywhere and press")
                .font(.system(size: 24, weight: .semibold))
                .padding(.bottom, 28)
            if keys.isEmpty {
                Text("Choose a shortcut in Settings ▸ General.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                KeycapRow(keys: keys)
            }
            Text("Or drop a file on the menu bar icon,\nor right-click ▸ Services ▸ Read in Dead Center.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 34)
        }
        .onAppear { keys = KeycapLabel.labels(for: KeyboardShortcuts.getShortcut(for: .read)) }
    }
}

// MARK: - Pieces

private let accentRed = Color(red: 1, green: 59 / 255, blue: 48 / 255)

/// The app's mark: two ticks and the red dot, drawn live so it's sharp at any size.
private struct ReticleMark: View {
    var body: some View {
        VStack(spacing: 5) {
            Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 9)
            Circle().fill(accentRed).frame(width: 7, height: 7)
            Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 9)
        }
        .accessibilityHidden(true)
    }
}

/// A ring with a waiting red dot that becomes a drawn checkmark once access is granted.
private struct AccessBadge: View {
    let granted: Bool
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(granted ? 0.9 : 0.16), lineWidth: 1.5)
            Circle()
                .fill(accentRed)
                .frame(width: 9, height: 9)
                .opacity(granted ? 0 : (breathing ? 1 : 0.35))
                .scaleEffect(granted ? 0.2 : 1)
            Checkmark()
                .trim(from: 0, to: granted ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 16)
        }
        .frame(width: 60, height: 60)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.8), value: granted)
        .onAppear {
            guard !reduceMotion else { breathing = true; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityLabel(granted ? "Access granted" : "Waiting for access")
    }
}

private struct Checkmark: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}

/// One key of a shortcut: modifiers carry their name like they do on the keyboard.
private struct KeycapLabel: Hashable {
    var symbol: String
    var name: String?

    private static let modifierNames: [Character: String] = ["⌃": "control", "⌥": "option", "⇧": "shift", "⌘": "command"]

    static func labels(for shortcut: KeyboardShortcuts.Shortcut?) -> [KeycapLabel] {
        guard let shortcut else { return [] }
        var labels: [KeycapLabel] = []
        var key = ""
        for character in shortcut.description {
            if let name = modifierNames[character], key.isEmpty {
                labels.append(KeycapLabel(symbol: String(character), name: name))
            } else {
                key.append(character)
            }
        }
        if !key.isEmpty { labels.append(KeycapLabel(symbol: key, name: nil)) }
        return labels
    }
}

private struct KeycapRow: View {
    let keys: [KeycapLabel]
    @State private var appeared = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                Keycap(label: key, pressed: pressed)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78).delay(0.12 + 0.07 * Double(index)),
                               value: appeared)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.map { $0.name ?? $0.symbol }.joined(separator: " "))
        .task {
            appeared = true
            guard !reduceMotion else { return }
            // One gentle press, as if someone just tried it.
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeOut(duration: 0.08)) { pressed = true }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { pressed = false }
        }
    }
}

private struct Keycap: View {
    let label: KeycapLabel
    var pressed: Bool

    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        ZStack {
            // The key's skirt, visible as depth beneath the cap.
            shape.fill(Color(white: 0.06))
                .offset(y: 3)
            cap
                .offset(y: pressed ? 2 : 0)
        }
        .frame(width: width, height: 58)
        .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
    }

    private var cap: some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay { legend }
    }

    @ViewBuilder private var legend: some View {
        if let name = label.name {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Text(label.symbol).font(.system(size: 14, weight: .regular))
                }
                Spacer()
                Text(name).font(.system(size: 11, weight: .regular))
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
        } else {
            Text(label.symbol)
                .font(.system(size: label.symbol.count > 1 ? 16 : 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
        }
    }

    private var width: CGFloat {
        if label.name != nil { return 72 }
        return label.symbol.count > 1 ? max(58, CGFloat(label.symbol.count) * 11 + 30) : 58
    }
}

private struct PageIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == current ? 0.85 : 0.2))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.7))
            .padding(.horizontal, 24)
            .frame(minWidth: prominent ? 180 : 96, minHeight: 36)
            .background {
                Capsule().fill(prominent ? Color.white : Color.white.opacity(0.1))
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
