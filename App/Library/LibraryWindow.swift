import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DCModel
import DCIngest

/// The app's own window: the + card with your readings around it, and the blank page behind it.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LibraryWindowController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Dead Center"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: LibraryView())
        window.setContentSize(NSSize(width: 960, height: 720))
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("LibraryWindow")
        WindowTheming.track(window)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Brings the window to the front, on the home screen unless `home` is false.
    func show(home: Bool = true) {
        if home {
            LibraryState.shared.composing = false
            LibraryState.shared.scanning = false
        }
        DockPresence.shared.enter(self)
        bringToFront()
        // Menu actions run while the menu is still closing, and the Dock policy change needs a moment:
        // ask again on the next turn of the run loop so the window reliably ends up in front.
        DispatchQueue.main.async { [weak self] in self?.bringToFront() }
    }

    /// Opens the Library on its blank page, ready to paste or type.
    func compose() {
        LibraryState.shared.scanning = false
        LibraryState.shared.composing = true
        show(home: false)
    }

    /// Opens the Library's scan page, to photograph pages with the iPhone.
    func scan() {
        LibraryState.shared.composing = false
        LibraryState.shared.scanning = true
        show(home: false)
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.shared.leave(self)
    }
}

// MARK: - State

/// Whether the Library shows its cards, the blank page behind the + card, or the scan page.
@Observable
final class LibraryState {
    static let shared = LibraryState()
    var composing = false
    var scanning = false
    var draft = ""
}

// MARK: - View

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var state: LibraryState { LibraryState.shared }

    private var theme: SettingsTheme {
        SettingsTheme(Preferences.shared.palette(systemIsDark: colorScheme == .dark))
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            if state.scanning {
                ScanPage()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else if state.composing {
                ComposePage()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                LibraryHome()
                    .transition(.opacity)
            }
        }
        .environment(\.settingsTheme, theme)
        .tint(theme.accent)
        .animation(.smooth(duration: 0.3), value: state.composing)
        .animation(.smooth(duration: 0.3), value: state.scanning)
    }
}

/// The home screen: the + card, with your latest unfinished readings gathered around it.
private struct LibraryHome: View {
    enum Mode: Equatable { case home, all, finished }

    @Environment(\.settingsTheme) private var theme
    @State private var mode: Mode = .home
    @State private var searching = false
    @State private var query = ""
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    static let card = CGSize(width: 214, height: 152)
    static let plus = CGSize(width: 190, height: 134)

    private var library: LibraryStore { LibraryStore.shared }
    private var unfinished: [LibraryEntry] { library.all.filter { !$0.finished } }
    private var finished: [LibraryEntry] { library.all.filter(\.finished) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [LibraryEntry] {
        library.all.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || ($0.snippet ?? "").localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        ZStack {
            Group {
                if !trimmedQuery.isEmpty {
                    grid(results, title: nil, empty: "Nothing matches “\(trimmedQuery)”")
                } else {
                    switch mode {
                    case .home:
                        Constellation(entries: Array(unfinished.prefix(6)), total: unfinished.count,
                                      dropTargeted: dropTargeted) { mode = .all }
                    case .all:
                        grid(unfinished, title: "All readings", empty: "Nothing in progress")
                    case .finished:
                        grid(finished, title: "Finished", empty: "Nothing finished yet")
                    }
                }
            }
            .transition(.opacity)

            VStack {
                HStack {
                    if mode != .home, trimmedQuery.isEmpty {
                        BackButton(title: "Home") { mode = .home }
                            .transition(.opacity)
                    }
                    Spacer()
                    search
                }
                .padding(.leading, 78)
                .padding(.trailing, 12)
                .padding(.top, 4)
                .frame(height: 36)
                Spacer()
                HStack {
                    Spacer()
                    corner
                }
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
            // Level with the traffic lights, in the title bar's space.
            .ignoresSafeArea(.container, edges: .top)
        }
        .animation(.smooth(duration: 0.32), value: mode)
        .animation(.smooth(duration: 0.25), value: trimmedQuery.isEmpty)
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText], isTargeted: $dropTargeted, perform: LibraryDrop.perform)
    }

    private func grid(_ entries: [LibraryEntry], title: String?, empty: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let title {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.92))
                }
                if entries.isEmpty {
                    Text(empty)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.ink.opacity(0.42))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.card.width, maximum: Self.card.width + 30),
                                                 spacing: 20)], spacing: 20) {
                        ForEach(entries) { EntryCard(entry: $0, size: Self.card, tilt: 0) }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 58)
            .padding(.bottom, 52)
        }
        .scrollIndicators(.never)
    }

    private var search: some View {
        HStack(spacing: 6) {
            if searching {
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 170)
                    .focused($searchFocused)
                    .onExitCommand { closeSearch() }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Button {
                if searching { closeSearch() } else { openSearch() }
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help(searching ? "Close search" : "Search everything you've read  ⌘F")
        }
        .padding(.leading, searching ? 12 : 0)
        .background(Capsule().fill(theme.ink.opacity(searching ? 0.08 : 0)))
        .animation(.smooth(duration: 0.25), value: searching)
    }

    /// Quiet icons in the corner: finished readings, transcription, settings.
    private var corner: some View {
        HStack(spacing: 2) {
            CornerButton(symbol: mode == .finished ? "checkmark.circle.fill" : "checkmark.circle",
                         help: mode == .finished ? "Back to your readings" : "Finished readings") {
                mode = mode == .finished ? .home : .finished
            }
            if Preferences.shared.pageScanning {
                CornerButton(symbol: "doc.viewfinder", help: "Scan pages with your iPhone") {
                    LibraryState.shared.scanning = true
                }
            }
            ForEach(LibraryCorner.extras, id: \.symbol) { extra in
                CornerButton(symbol: extra.symbol, help: extra.help, action: extra.action)
            }
            CornerButton(symbol: "gearshape", help: "Settings  ⌘,") {
                SettingsWindowController.shared.show()
            }
        }
    }

    private func openSearch() {
        searching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private func closeSearch() {
        searching = false
        query = ""
    }
}

/// The + card in the middle, three readings above and three below. The outer cards of each row
/// tilt toward the +, so the whole arrangement leans in around it.
private struct Constellation: View {
    let entries: [LibraryEntry]
    let total: Int
    let dropTargeted: Bool
    let showAll: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var appeared = false

    private struct Slot {
        let x: CGFloat
        let y: CGFloat
        let tilt: Double
    }

    private static let gap: CGFloat = 34

    /// Where the cards go, symmetric for any count from one to six.
    private static func slots(for count: Int) -> [Slot] {
        let dx = LibraryHome.card.width + 28
        let dy = LibraryHome.plus.height / 2 + gap + LibraryHome.card.height / 2
        let dip: CGFloat = 26
        let tl = Slot(x: -dx, y: -dy + dip, tilt: -11)
        let tm = Slot(x: 0, y: -dy, tilt: 0)
        let tr = Slot(x: dx, y: -dy + dip, tilt: 11)
        let bl = Slot(x: -dx, y: dy - dip, tilt: 11)
        let bm = Slot(x: 0, y: dy, tilt: 0)
        let br = Slot(x: dx, y: dy - dip, tilt: -11)
        switch count {
        case 0: return []
        case 1: return [tm]
        case 2: return [tl, tr]
        case 3: return [tl, tm, tr]
        case 4: return [tl, tm, tr, bm]
        case 5: return [tl, tm, tr, bl, br]
        default: return [tl, tm, tr, bl, bm, br]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let slots = Self.slots(for: entries.count)
            let needed = CGSize(width: LibraryHome.card.width * 3 + 56 + 90,
                                height: (LibraryHome.card.height + Self.gap) * 2 + LibraryHome.plus.height + 110)
            let scale = min(1, geo.size.width / needed.width, geo.size.height / needed.height)
            ZStack {
                PlusCard(size: LibraryHome.plus, highlighted: dropTargeted)
                    .scaleEffect(appeared ? 1 : 0.92)
                if entries.isEmpty {
                    Text("Paste, type or drop something to read")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink.opacity(0.38))
                        .offset(y: LibraryHome.plus.height / 2 + 26)
                        .opacity(appeared ? 1 : 0)
                }
                ForEach(Array(zip(entries, slots).enumerated()), id: \.element.0.id) { index, pair in
                    let (entry, slot) = pair
                    EntryCard(entry: entry, size: LibraryHome.card, tilt: appeared ? slot.tilt : 0)
                        .offset(x: appeared ? slot.x : 0, y: appeared ? slot.y : 0)
                        .scaleEffect(appeared ? 1 : 0.7)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.035 * Double(index)),
                                   value: appeared)
                }
                if total > entries.count {
                    Button(action: showAll) {
                        Text("All readings (\(total))")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.ink.opacity(0.55))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(theme.ink.opacity(0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .offset(y: LibraryHome.plus.height / 2 + Self.gap + LibraryHome.card.height + 30)
                    .opacity(appeared ? 1 : 0)
                }
            }
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: appeared)
        }
        .onAppear { appeared = true }
    }
}

/// Dropping onto the Library reads what was dropped.
enum LibraryDrop {
    static func perform(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { ReadingCoordinator.shared.open([url]) }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }),
           !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { ReadingCoordinator.shared.read(.web(url)) }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                DispatchQueue.main.async {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
                        ReadingCoordinator.shared.read(.web(url))
                    } else {
                        ReadingCoordinator.shared.read(text: text, origin: .text)
                    }
                }
            }
            return true
        }
        return false
    }
}

/// Extra corner icons contributed by optional features (transcription).
enum LibraryCorner {
    struct Extra {
        let symbol: String
        let help: String
        let action: () -> Void
    }
    static var extras: [Extra] = []
}

// MARK: - Pieces

private struct CornerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink.opacity(hovering ? 0.9 : 0.45))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

struct BackButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(theme.ink.opacity(hovering ? 0.95 : 0.62))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.ink.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to Home  ⌘[")
    }
}

private struct PlusCard: View {
    let size: CGSize
    let highlighted: Bool
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        let active = hovering || highlighted
        Button { LibraryState.shared.composing = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.ink.opacity(active ? 1 : 0.75))
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.ink.opacity(active ? 0.1 : (theme.isDark ? 0.055 : 0.035))))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.ink.opacity(active ? 0.45 : 0.24), lineWidth: 1.2))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .animation(.easeOut(duration: 0.18), value: highlighted)
        .help("New text: paste, type, or drop a file  ↩")
    }
}

/// A reading: its title, its first lines, and a red line for how far along you are.
private struct EntryCard: View {
    let entry: LibraryEntry
    let size: CGSize
    let tilt: Double
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    private var preview: String? {
        guard var text = entry.snippet, !text.isEmpty else { return nil }
        if !entry.title.isEmpty, text.hasPrefix(entry.title) {
            text = String(text.dropFirst(entry.title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    var body: some View {
        Button { ReadingCoordinator.shared.resume(entry) } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [theme.ink.opacity(fillTop), theme.ink.opacity(fillBottom)],
                                         startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.title.isEmpty ? "Untitled" : entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.95))
                        .lineLimit(2)
                    if let preview {
                        Text(preview)
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .foregroundStyle(theme.ink.opacity(0.52))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0.62),
                                                         .init(color: .clear, location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 14)
                Rectangle()
                    .fill(entry.finished ? theme.ink.opacity(0.25) : theme.accent)
                    .frame(width: size.width * max(entry.progress, 0.025), height: 3)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.ink.opacity(hovering ? 0.2 : 0.1), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.55 : 0.12), radius: hovering ? 18 : 12, y: hovering ? 10 : 6)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .rotationEffect(.degrees(hovering ? tilt * 0.4 : tilt))
            .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hovering)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: tilt)
        .contextMenu { EntryMenu(entry: entry) }
        .help(entry.title)
    }

    private var fillTop: Double { hovering ? (theme.isDark ? 0.15 : 0.09) : (theme.isDark ? 0.12 : 0.065) }
    private var fillBottom: Double { hovering ? (theme.isDark ? 0.12 : 0.07) : (theme.isDark ? 0.09 : 0.05) }
}

private struct EntryMenu: View {
    let entry: LibraryEntry

    var body: some View {
        Button(entry.position > 0 && !entry.finished ? "Continue Reading" : "Read") {
            ReadingCoordinator.shared.resume(entry)
        }
        Button("Read from the Beginning") { ReadingCoordinator.shared.restart(entry) }
        Divider()
        switch entry.origin {
        case .file(let url):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .web(let url):
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        default:
            EmptyView()
        }
        Divider()
        Button("Remove from Library", role: .destructive) { LibraryStore.shared.remove(id: entry.id) }
    }
}

// MARK: - Compose

/// The page behind the + card: paste or type, ⌘↩ to read, Esc or Home to go back. Drop a file to read it.
private struct ComposePage: View {
    @Environment(\.settingsTheme) private var theme
    private var state: LibraryState { LibraryState.shared }

    var body: some View {
        ZStack(alignment: .bottom) {
            ComposeTextView(text: Binding(get: { state.draft }, set: { state.draft = $0 }),
                            ink: NSColor(theme.ink), accent: NSColor(theme.accent),
                            onRead: read, onClose: close, onFiles: open)
                .padding(.top, 52)
                .padding(.bottom, 44)
            HStack {
                Text(state.draft.isEmpty ? "paste text or drag a file here" : "⌘↩ to read")
                Spacer()
                if !state.draft.isEmpty {
                    Button(action: read) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text("Read")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.ink.opacity(0.88))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.ink.opacity(0.09)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.ink.opacity(0.34))
            .padding(.horizontal, 48)
            .padding(.bottom, 14)
            .animation(.easeOut(duration: 0.18), value: state.draft.isEmpty)
        }
        .overlay(alignment: .topLeading) {
            BackButton(title: "Home", action: close)
                .padding(.leading, 78)
                .frame(height: 36)
                .padding(.top, 4)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func read() {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        leave()
        ReadingCoordinator.shared.read(text: text, origin: .text)
        state.draft = ""
    }

    private func close() {
        leave()
    }

    private func open(_ urls: [URL]) {
        leave()
        ReadingCoordinator.shared.open(urls)
    }

    /// Gives up the keyboard before the page goes, so nothing of the text view stays behind.
    private func leave() {
        LibraryWindowController.shared.window?.makeFirstResponder(nil)
        state.composing = false
    }
}

/// A plain, borderless text view: ⌘↩ reads, Esc closes, dropped files open instead of pasting paths.
private struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    let ink: NSColor
    let accent: NSColor
    let onRead: () -> Void
    let onClose: () -> Void
    let onFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let view = ComposeNSTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        // No floating Writing Tools button: it lingers on screen after the page closes.
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 44, height: 8)
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        scroll.documentView = view
        apply(to: view)
        view.string = text
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        apply(to: view)
        if view.string != text { view.string = text }
    }

    private func apply(to view: NSTextView) {
        // Leading as line spacing rather than a height multiple, so the caret is as tall as the text.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: ink.withAlphaComponent(0.9),
            .paragraphStyle: style,
        ]
        view.typingAttributes = attributes
        view.defaultParagraphStyle = style
        view.insertionPointColor = accent
        view.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.25)]
        if let storage = view.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextView
        init(_ parent: ComposeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onClose()
                return true
            }
            return false
        }
    }
}

private final class ComposeNSTextView: NSTextView {
    weak var coordinator: ComposeTextView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            coordinator?.parent.onRead()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            coordinator?.parent.onFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}
