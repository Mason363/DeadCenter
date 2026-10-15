import AppKit
import SwiftUI

/// Puts transcription into the menu bar menu, the Library corner and Settings.
enum TranscriptionHooks {
    static func install() {
        MenuExtras.items = {
            [ActionMenuItem(title: "Transcribe…", key: "") { TranscriptionController.shared.show() }]
        }
        LibraryCorner.extras = [
            LibraryCorner.Extra(symbol: "waveform", help: "Transcribe a meeting, lecture or recording") {
                TranscriptionController.shared.show()
            },
        ]
        SettingsPane.extras = [
            SettingsPane(id: "transcription", title: "Transcription", symbol: "waveform") {
                AnyView(TranscriptionSettingsView())
            },
        ]
    }
}
