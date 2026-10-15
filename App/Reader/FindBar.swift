import AppKit
import DCEngine

/// ⌘F: a small field at the top of the reader that jumps to a word or phrase as you type.
final class FindBar: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNext: ((_ forward: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.alignment = .right
        for view in [icon, field, countLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 14) / 2, width: 14, height: 14)
        countLabel.frame = NSRect(x: bounds.width - 62, y: (h - 15) / 2, width: 52, height: 15)
        field.frame = NSRect(x: 30, y: (h - 18) / 2, width: bounds.width - 30 - 66, height: 18)
    }

    func apply(_ palette: ReaderPalette) {
        layer?.backgroundColor = palette.text.withAlphaComponent(0.09).cgColor
        layer?.borderColor = palette.text.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.5
        field.textColor = palette.text
        icon.contentTintColor = palette.text.withAlphaComponent(0.5)
        countLabel.textColor = palette.text.withAlphaComponent(0.45)
        field.placeholderAttributedString = NSAttributedString(string: "Find a word", attributes: [
            .foregroundColor: palette.text.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 13),
        ])
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var query: String { field.stringValue }

    func setCount(current: Int?, total: Int) {
        if field.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if total == 0 {
            countLabel.stringValue = "None"
        } else {
            countLabel.stringValue = "\((current ?? 0) + 1)/\(total)"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            onNext?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

extension ReadingStream {
    /// Item indices where `query` starts. Case- and accent-insensitive; the last word matches as a prefix.
    func matches(for query: String) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.unicodeScalars.contains(where: { $0.value >= 0x2E80 && $0.value <= 0x9FFF }) {
            return items.indices.filter { items[$0].kind == .word && items[$0].text.contains(trimmed) }
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map { Self.searchKey(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var result: [Int] = []
        var i = 0
        while i < items.count {
            if matchesSequence(words, at: i) { result.append(i) }
            i += 1
        }
        return result
    }

    private func matchesSequence(_ words: [String], at start: Int) -> Bool {
        var j = start
        for (n, word) in words.enumerated() {
            guard j < items.count, items[j].kind == .word else { return false }
            let key = Self.searchKey(items[j].text)
            let isLast = n == words.count - 1
            guard isLast ? key.hasPrefix(word) : key == word else { return false }
            j += 1
        }
        return true
    }

    static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
