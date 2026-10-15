import AppIntents
import Foundation

struct ReadTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Text"
    static let description = IntentDescription("Reads text in Dead Center, one word at a time.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$text) in Dead Center")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ReadingCoordinator.shared.read(text: text)
        return .result()
    }
}

struct ReadClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Clipboard"
    static let description = IntentDescription("Reads whatever is on the clipboard in Dead Center.")

    @MainActor
    func perform() async throws -> some IntentResult {
        ReadingCoordinator.shared.readClipboard()
        return .result()
    }
}

struct ReadWebPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Web Page"
    static let description = IntentDescription("Fetches a web page and reads its article in Dead Center.")

    @Parameter(title: "URL")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$url) in Dead Center")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ReadingCoordinator.shared.read(.web(url))
        return .result()
    }
}

struct ReadFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Read File"
    static let description = IntentDescription("Reads a document (PDF, EPUB, text, Word, image…) in Dead Center.")

    @Parameter(title: "File")
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$file) in Dead Center")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) {
            ReadingCoordinator.shared.open([url])
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Dead Center", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.filename)
            try file.data.write(to: url, options: .atomic)
            ReadingCoordinator.shared.open([url])
        }
        return .result()
    }
}

struct DeadCenterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReadClipboardIntent(),
                    phrases: ["Read my clipboard in \(.applicationName)", "\(.applicationName) my clipboard"],
                    shortTitle: "Read Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: ReadTextIntent(), phrases: ["Read text in \(.applicationName)"],
                    shortTitle: "Read Text", systemImageName: "text.alignleft")
        AppShortcut(intent: ReadFileIntent(), phrases: ["Read a file in \(.applicationName)"],
                    shortTitle: "Read File", systemImageName: "doc.text")
    }
}
