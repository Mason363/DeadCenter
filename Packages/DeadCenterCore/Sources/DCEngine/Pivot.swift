import Foundation

public enum PivotRule: Sendable {
    /// Spritz-style optimal recognition point, about a third into the word.
    case optimal
    /// The middle letter of the word.
    case middle
}

public enum Pivot {
    /// Index (in `Character`s) of the letter to highlight. Leading and trailing punctuation is
    /// ignored when measuring the word, so `“Hello,` highlights the same letter as `Hello`.
    public static func index(in text: String, rule: PivotRule) -> Int {
        let chars = Array(text)
        guard !chars.isEmpty else { return 0 }
        guard let first = chars.firstIndex(where: isWordCharacter),
              let last = chars.lastIndex(where: isWordCharacter) else {
            return (chars.count - 1) / 2
        }
        let length = last - first + 1
        let offset: Int
        switch rule {
        case .optimal:
            switch length {
            case ...1: offset = 0
            case 2...5: offset = 1
            case 6...9: offset = 2
            case 10...13: offset = 3
            default: offset = 4
            }
        case .middle:
            offset = (length - 1) / 2
        }
        return first + offset
    }

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
