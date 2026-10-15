import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KeyboardShortcuts
import DCModel
import DCIngest

/// The app's own window: start reading, continue where you left off, and everything you've read.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LibraryWindowController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Dead Center"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: LibraryView())
        window.setContentSize(NSSize(width: 900, height: 660))
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("LibraryWindow")
        WindowTheming.track(window)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        DockPresence.shared.enter(self)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.shared.leave(self)
    }
}

// MARK: - State

/// Whether the Library shows its cards or the blank page behind the + card.
@Observable
final class LibraryState {
    static let shared = LibraryState()
    var composing = false
    var draft = ""
}

extension LibraryWindowController {
    /// Opens the Library on its blank page, ready to paste or type.
    func compose() {
        LibraryState.shared.composing = true
        show()
    }
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
            if state.composing {
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
    }
}

/// Unfinished readings as cards around the + card. Nothing else.
private struct LibraryHome: View {
    @Environment(\.settingsTheme) private var theme
    @State private var searching = false
    @State private var query = ""
    @State private var dropTargeted = false
    @State private var showingFinished = false
    @FocusState private var searchFocused: Bool

    private static let cardSize = CGSize(width: 190, height: 132)
    private static let spacing: CGFloat = 18

    private var library: LibraryStore { LibraryStore.shared }

    /// Unfinished readings; a search looks through everything.
    private var entries: [LibraryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.all.filter { $0.finished == showingFinished } }
        return library.all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.snippet ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                ScrollViewReader { scroller in
                    ScrollView {
                        cards(width: geo.size.width)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollIndicators(.never)
                    .onAppear { scroller.scrollTo("plus", anchor: .center) }
                }
            }
            search
                .padding(.top, 12)
                .padding(.trailing, 14)
            corner
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText], isTargeted: $dropTargeted, perform: LibraryDrop.perform)
    }

    private func cards(width: CGFloat) -> some View {
        let columns = max(2, min(4, Int((width - 60 + Self.spacing) / (Self.cardSize.width + Self.spacing))))
        let list = entries
        let searchingNow = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let flat = searchingNow || showingFinished
        let half = flat ? list.count : (list.count + 1) / 2
        let above = Array(list.prefix(half))
        let below = Array(list.dropFirst(half))
        return VStack(spacing: Self.spacing) {
            if showingFinished, !searchingNow {
                Text(list.isEmpty ? "Nothing finished yet" : "Finished")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.4))
                    .padding(.bottom, 4)
            }
            rows(above, columns: columns)
            if !flat {
                PlusCard(size: Self.cardSize, highlighted: dropTargeted)
                    .id("plus")
            } else if searchingNow, list.isEmpty {
                Text("Nothing matches “\(query)”")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink.opacity(0.4))
            }
            rows(below, columns: columns)
        }
        .padding(.vertical, 56)
        .padding(.horizontal, 30)
    }

    @ViewBuilder
    private func rows(_ entries: [LibraryEntry], columns: Int) -> some View {
        let chunks = stride(from: 0, to: entries.count, by: columns).map { Array(entries[$0..<min($0 + columns, entries.count)]) }
        ForEach(chunks.indices, id: \.self) { i in
            HStack(spacing: Self.spacing) {
                ForEach(chunks[i]) { entry in
                    EntryCard(entry: entry, size: Self.cardSize)
                }
            }
        }
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
                    .foregroundStyle(theme.ink.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help(searching ? "Close search" : "Search everything you've read  ⌘F")
        }
        .padding(.leading, searching ? 12 : 0)
        .background(Capsule().fill(theme.ink.opacity(searching ? 0.06 : 0)))
        .animation(.smooth(duration: 0.25), value: searching)
    }

    /// Quiet icons in the corner: finished readings, transcription, settings.
    private var corner: some View {
        HStack(spacing: 2) {
            CornerButton(symbol: showingFinished ? "checkmark.circle.fill" : "checkmark.circle",
                         help: showingFinished ? "Back to unfinished readings" : "Finished readings") {
                withAnimation(.smooth(duration: 0.3)) { showingFinished.toggle() }
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
                .foregroundStyle(theme.ink.opacity(hovering ? 0.85 : 0.4))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

// MARK: - Cards

private struct PlusCard: View {
    let size: CGSize
    let highlighted: Bool
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { LibraryState.shared.composing = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(theme.ink.opacity(hovering || highlighted ? 0.85 : 0.45))
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.ink.opacity(highlighted ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.ink.opacity(hovering || highlighted ? 0.3 : 0.14), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.18), value: highlighted)
        .help("New text — paste, type, or drop a file")
    }
}

/// Just the title, and a red line along the bottom for how far you've read.
private struct EntryCard: View {
    let entry: LibraryEntry
    let size: CGSize
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { ReadingCoordinator.shared.resume(entry) } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.ink.opacity(hovering ? 0.07 : 0.04))
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.88))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                Rectangle()
                    .fill(entry.finished ? theme.ink.opacity(0.2) : theme.accent)
                    .frame(width: size.width * max(entry.progress, 0.02), height: 3)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .offset(y: hovering ? -2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .contextMenu { EntryMenu(entry: entry) }
        .help(entry.snippet ?? entry.title)
    }
}

// MARK: - Compose

/// The page behind the + card: paste or type, ⌘↩ to read, Esc to go back. Drop a file to read it.
private struct ComposePage: View {
    @Environment(\.settingsTheme) private var theme
    private var state: LibraryState { LibraryState.shared }

    var body: some View {
        ZStack(alignment: .bottom) {
            ComposeTextView(text: Binding(get: { state.draft }, set: { state.draft = $0 }),
                            ink: NSColor(theme.ink), accent: NSColor(theme.accent),
                            onRead: read, onClose: close, onFiles: open)
                .padding(.top, 44)
                .padding(.bottom, 40)
            HStack {
                Text(state.draft.isEmpty ? "paste text or drag a file here" : "⌘↩ to read")
                Spacer()
                Text("esc to go back")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.ink.opacity(0.3))
            .padding(.horizontal, 48)
            .padding(.bottom, 16)
        }
    }

    private func read() {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ReadingCoordinator.shared.read(text: text, origin: .text)
        state.draft = ""
        state.composing = false
    }

    private func close() {
        state.composing = false
    }

    private func open(_ urls: [URL]) {
        ReadingCoordinator.shared.open(urls)
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
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: ink.withAlphaComponent(0.9),
            .paragraphStyle: style,
        ]
        view.typingAttributes = attributes
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

/// How entries describe themselves.
enum EntryFormat {
    static func symbol(_ origin: DocumentOrigin) -> String {
        switch origin {
        case .file(let url):
            switch url.pathExtension.lowercased() {
            case "pdf": "doc.richtext"
            case "epub": "book.closed"
            case "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp": "photo"
            case "m4a", "mp3", "wav", "aiff", "mp4", "mov", "m4v": "waveform"
            default: "doc.text"
            }
        case .web: "globe"
        case .clipboard: "doc.on.clipboard"
        case .selection: "text.cursor"
        case .text: "text.alignleft"
        }
    }

    static func source(_ entry: LibraryEntry) -> String {
        switch entry.origin {
        case .file(let url): url.pathExtension.uppercased() + "  ·  " + url.deletingLastPathComponent().lastPathComponent
        case .web(let url): url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? "Web"
        case .clipboard: "Clipboard"
        case .selection(let app): app.map { "From \($0)" } ?? "Selection"
        case .text: "Text"
        }
    }

    /// Short label for a card's corner: "PDF", "wikipedia.org", "Clipboard".
    static func badge(_ entry: LibraryEntry) -> String {
        switch entry.origin {
        case .file(let url): url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
        default: source(entry)
        }
    }

    static func detailLine(_ entry: LibraryEntry) -> String {
        var parts = [source(entry), relativeDate(entry.lastOpened)]
        if let words = entry.wordCount, words > 0 {
            parts.append(words.formatted() + " words")
        }
        return parts.joined(separator: "  ·  ")
    }

    static func progressLine(_ entry: LibraryEntry) -> String {
        var line = "\(Int((entry.progress * 100).rounded()))%"
        if let words = entry.wordCount, words > 0 {
            let left = Double(words) * (1 - entry.progress) / Double(max(Preferences.shared.wpm, 1)) * 60
            line += "  ·  " + ReaderView.formatRemaining(left)
        }
        return line
    }

    static func relativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
