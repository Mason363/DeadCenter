import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Smart read: selection → page → open document → clipboard.
    static let read = Self("read", default: .init(.period, modifiers: [.option, .command]))
    /// Always reads the clipboard.
    static let readClipboard = Self("readClipboard", default: .init(.period, modifiers: [.shift, .option, .command]))
}
