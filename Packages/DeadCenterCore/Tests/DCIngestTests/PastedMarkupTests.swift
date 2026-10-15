import Testing
import Foundation
import DCModel
@testable import DCIngest

/// Text pasted from chat apps, notes and papers must read as prose: no Markdown or TeX syntax left.
@Suite("Pasted markup")
struct PastedMarkupTests {
    static let chatAnswer = """
    ## Why RSVP works

    **Rapid serial visual presentation** (RSVP) shows *one word at a time*. Here's why it's fast:

    1. **No saccades** — your eyes don't jump between words.
    2. **Fixed focus**: the *optimal recognition point* stays put.
    - Works with `code` too, and __double underscores__.
    - See [the paper](https://example.com/rsvp) for details.

    > **Note:** comprehension drops above ~700 wpm.

    | Speed | Comprehension |
    |-------|---------------|
    | 300   | **High**      |
    | 900   | Low           |

    ```python
    print("skip me")
    ```

    The energy is $E = mc^2$ and the ratio is $\\frac{a}{b}$, with $\\alpha \\le \\beta$.

    ---

    ***Bold italic*** and ~~struck~~ text end here.
    """

    func blocks(_ text: String) async throws -> [Block] {
        var out: [Block] = []
        for try await event in Ingestor.ingest(.text(text)) {
            if case .blocks(let b) = event { out += b }
        }
        return out
    }

    func text(of blocks: [Block]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .paragraph(let s), .heading(let s, _), .chapter(let s): s
            case .image: nil
            }
        }.joined(separator: "\n")
    }

    @Test func chatAnswerReadsAsProse() async throws {
        let result = text(of: try await blocks(Self.chatAnswer))
        for marker in ["**", "__", "`", "##", "](", "|", "~~", "$", "\\frac", "\\alpha", "print("] {
            #expect(!result.contains(marker), "left \(marker) in:\n\(result)")
        }
        #expect(result.contains("Rapid serial visual presentation"))
        #expect(result.contains("E = mc²"))
        #expect(result.contains("α ≤ β"))
        #expect(result.contains("Bold italic"))
    }

    @Test func titleIsClean() async throws {
        var title: String?
        for try await event in Ingestor.ingest(.text("# Typed **notes**\n\nThe *area* is $\\pi r^2$.")) {
            if case .title(let t) = event { title = t }
        }
        #expect(title == "Typed notes")
    }

    @Test func singleBoldSpanInPlainText() async throws {
        let result = text(of: try await blocks("This is **really** important, and so is __this__."))
        #expect(result == "This is really important, and so is this.")
    }

    @Test func inlineMathInPlainText() async throws {
        let result = text(of: try await blocks("The area is \\(\\pi r^2\\) and $x_i \\times y_i$ sums to \\[\\sum_{i=1}^{n} x_i\\]."))
        #expect(!result.contains("\\"))
        #expect(!result.contains("$"))
        #expect(result.contains("π"))
        #expect(result.contains("∑"))
    }
}
