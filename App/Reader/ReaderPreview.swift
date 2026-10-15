import SwiftUI
import DCModel
import DCEngine

/// A live sample of the reader using the current Preferences (Settings → Appearance, onboarding).
/// Plays `text` through the real renderer; restarts from the top when `loops` is true.
struct ReaderPreview: NSViewRepresentable {
    static let sampleText = "Keep your eyes on the red letter. Words come to you, one at a time, and you simply read."
    var text: String = ReaderPreview.sampleText
    var loops: Bool = true

    func makeCoordinator() -> Looper { Looper() }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isPreview = true
        context.coordinator.attach(to: view, text: text, loops: loops)
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        if context.coordinator.text != text || context.coordinator.loops != loops {
            context.coordinator.attach(to: view, text: text, loops: loops)
        }
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: Looper) {
        coordinator.stop()
        view.session = nil
    }

    final class Looper {
        private(set) var text = ""
        private(set) var loops = true
        private var session: ReaderSession?
        private var restart: DispatchWorkItem?

        func attach(to view: ReaderView, text: String, loops: Bool) {
            stop()
            self.text = text
            self.loops = loops
            let paragraphs = text.components(separatedBy: "\n\n").map { Block.paragraph($0) }
            let session = ReaderSession(id: "preview", title: nil, origin: .text)
            session.load(ReadingStream(batch: Tokenizer().tokenize(paragraphs)))
            session.onProgress = { [weak self] s in
                guard let self, self.loops, s.state == .finished else { return }
                let work = DispatchWorkItem { [weak s] in
                    s?.seekToStart()
                    s?.play()
                }
                self.restart = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
            }
            self.session = session
            view.session = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak session] in session?.play() }
        }

        func stop() {
            restart?.cancel()
            session?.pause()
            session = nil
        }
    }
}
