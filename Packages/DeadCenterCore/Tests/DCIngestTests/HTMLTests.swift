import Foundation
import Testing
import DCModel
@testable import DCIngest

@Suite("HTML")
struct HTMLTests {
    static let messy = """
    <!DOCTYPE html>
    <html><head><title>Caf&eacute; &amp; Co &mdash; Messy</title>
    <style>p { color: red }</style><script>var x = "<p>not text</p>";</script></head>
    <body>
    <nav><a href="/">Home</a> <a href="/about">About</a></nav>
    <header><h1>Messy <em>Page</em></h1></header>
    <p>First paragraph with <b>bold</b>, <a href="x">a link</a>, and an&nbsp;entity &#8220;quote&#8221;.
    <p>Unclosed paragraph<br>with a single break<br><br>and a double break.
    <div>Text directly in a div <span>with a span</span></div>
    <ul><li>One<li>Two <i>italic</i></ul>
    <figure><picture><source srcset="img/large.webp 1600w, img/small.webp 400w"><img src="img/fallback.jpg" alt="ignored" width="800" height="600"></picture>
    <figcaption>A <b>captioned</b> figure</figcaption></figure>
    <p>Has a pixel <img src="https://tracker.example.com/pixel.gif?id=1" width="1" height="1"> inline.</p>
    <p>Footnote ref<sup><a href="#fn1">1</a></sup> here.</p>
    <img src="data:image/png;base64,\(TestImages.png(width: 64, height: 64).base64EncodedString())" alt="Inline data image">
    <div hidden>Hidden text</div><div style="display: none">Also hidden</div>
    <svg><text>vector text</text></svg>
    <table><tr><td>Cell A<td>Cell B</table>
    <p>Ruby <ruby>漢<rt>kan</rt></ruby>字 and <code>code</code>.</p>
    <pre>for (int i = 0; i &lt; 10; i++) { print(i); }</pre>
    <aside>Sidebar text</aside>
    <footer>Copyright footer</footer>
    <noscript>Enable JavaScript</noscript>
    """

    @Test("Walks messy HTML into clean blocks")
    func messyHTML() async throws {
        let result = try await ingest(.html(Self.messy, baseURL: URL(string: "https://example.com/articles/post.html")))
        #expect(result.title == "Café & Co — Messy")
        #expect(result.headings == ["Messy Page"])
        #expect(result.paragraphs == [
            "First paragraph with bold, a link, and an entity “quote”.",
            "Unclosed paragraph with a single break",
            "and a double break.",
            "Text directly in a div with a span",
            "One", "Two italic",
            "Has a pixel inline.",
            "Footnote ref here.",
            "Cell A", "Cell B",
            "Ruby 漢字 and code.",
        ], "\(result.outline)")

        #expect(result.images.count == 2)
        let figure = try #require(result.images.first)
        #expect(figure.url?.absoluteString == "https://example.com/articles/img/large.webp")
        #expect(figure.caption == "A captioned figure")
        let inline = try #require(result.images.last)
        #expect(inline.data != nil && inline.caption == "Inline data image")

        for junk in ["Home", "not text", "Hidden", "vector", "Sidebar", "Copyright", "JavaScript", "kan", "print("] {
            #expect(!result.text.contains(junk), "\(junk)")
        }
    }

    @Test("HTML files: relative images are read from disk and saved pages lose their chrome")
    func htmlFile() async throws {
        let dir = TemporaryDirectory()
        try dir.write(TestImages.png(width: 200, height: 150), to: "page_files/photo.png")
        let html = """
        <html><head><meta charset="windows-1252"><title>Saved Page</title>
        <meta property="og:title" content="Saved"><script>a()</script><script>b()</script></head>
        <body><div class="site-header"><a href="/">Logo</a></div>
        <div class="sidebar">Related links</div>
        <article><h1>Saved Article</h1>
        <p>\(String(repeating: "This saved article has plenty of real prose in it. ", count: 12))</p>
        <p><img src="page_files/photo.png" alt="A photo of something"></p>
        <p>\(String(repeating: "A second paragraph follows with more words. ", count: 10))Caf\u{e9}.</p>
        </article>
        <div class="comments">Comment one</div></body></html>
        """
        let url = try dir.write(html.data(using: .windowsCP1252)!, to: "page.html")
        let result = try await ingest(.file(url))
        #expect(result.paragraphs.count == 2, "\(result.outline)")
        #expect(result.paragraphs.last?.hasSuffix("Café.") == true)
        #expect(!result.text.contains("Related") && !result.text.contains("Comment one"))
        let image = try #require(result.images.first)
        #expect(image.data != nil && image.pixelWidth == 200)
    }

    @Test("Parser: implied end tags, void elements, raw text, entities, and XHTML self-closing")
    func parser() {
        let root = HTMLParser.parse("<p>a<p>b<ul><li>c<li>d</ul><br></br><div/><script>if (a<b) x()</script><textarea>&lt;t&gt;</textarea>&amp;&copy &#x1F600; &unknown;")
        let names = root.elementChildren.map(\.name)
        #expect(names == ["p", "p", "ul", "br", "div", "script", "textarea"])
        #expect(root.elementChildren[2].elementChildren.map(\.textContent) == ["c", "d"])
        #expect(root.elementChildren[6].textContent == "<t>")
        #expect(root.textContent.hasSuffix("&© 😀 &unknown;"))
        #expect(HTMLEntities.decode("a&amp;b&#150;c", inAttribute: true) == "a&b–c")
        #expect(HTMLEntities.decode("x?a=1&copy=2", inAttribute: true) == "x?a=1&copy=2")
    }

    @Test("srcset picks the largest candidate")
    func srcset() {
        #expect(SrcSet.best(in: "a.jpg 1x, b.jpg 2x")?.0 == "b.jpg")
        #expect(SrcSet.best(in: "small.jpg 320w, large.jpg 1280w, medium.jpg 640w")?.0 == "large.jpg")
        #expect(SrcSet.best(in: "only.jpg")?.0 == "only.jpg")
    }

    @Test("Web archives use their subresources for images")
    func webArchive() async throws {
        let png = TestImages.png(width: 300, height: 200)
        let article = """
        <html><head><title>Archived Story</title><script>x()</script><script>y()</script></head><body>
        <nav>Menu</nav><article><h1>Archived Story</h1>
        <p>\(String(repeating: "The archived story contains enough prose for Readability to keep it. ", count: 10))</p>
        <img src="/media/picture.png" alt="Archived picture">
        <p>\(String(repeating: "Another paragraph of archived prose follows the picture. ", count: 8))</p>
        </article><footer>Footer</footer></body></html>
        """
        let plist: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(article.utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://news.example.com/story/1",
                "WebResourceFrameName": "",
            ],
            "WebSubresources": [[
                "WebResourceData": png,
                "WebResourceMIMEType": "image/png",
                "WebResourceURL": "https://news.example.com/media/picture.png",
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let dir = TemporaryDirectory()
        let url = try dir.write(data, to: "story.webarchive")
        let result = try await ingest(.file(url))
        #expect(result.title == "Archived Story")
        #expect(result.paragraphs.count == 2, "\(result.outline)")
        let image = try #require(result.images.first)
        #expect(image.data == png)
        #expect(!result.text.contains("Menu") && !result.text.contains("Footer"))
    }
}

@Suite("Web")
struct WebTests {
    static let page = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <title>How Speed Reading Works | The Example Times</title>
    <meta property="og:site_name" content="The Example Times">
    <script>window.ads = [];</script>
    </head><body>
    <header class="masthead"><a href="/">The Example Times</a>
      <nav><ul><li><a href="/world">World</a></li><li><a href="/tech">Tech</a></li><li><a href="/arts">Arts</a></li></ul></nav>
    </header>
    <div class="layout">
      <aside class="sidebar"><h3>Trending</h3><ul><li><a href="/a">Ten things you missed</a></li><li><a href="/b">Celebrity news</a></li></ul></aside>
      <main>
        <article>
          <h1>How Speed Reading Works</h1>
          <p class="byline">By Ada Reader</p>
          <p>Rapid serial visual presentation shows one word at a time in the same place on the screen, so the eyes never have to move. Readers can follow far faster than they could by scanning lines of text, because most of the time spent reading is spent moving the eyes.</p>
          <p>The trick is to anchor every word at its optimal recognition point, a letter slightly left of center, and to pause a little longer at the ends of sentences and paragraphs so the meaning has time to settle before the next idea arrives.</p>
          <figure><img src="/images/rsvp-diagram.png" alt="Diagram" width="1200" height="800"><figcaption>Where the eye rests</figcaption></figure>
          <p>Practised readers often double their speed within a week. Comprehension holds up well for light material, and the method is a pleasant way to get through long articles and books that would otherwise sit unread in a queue forever.</p>
        </article>
        <section class="comments"><h2>Comments</h2><p>First! Great article, thanks for sharing it with everyone.</p></section>
      </main>
    </div>
    <footer><p>© The Example Times. All rights reserved.</p><a href="/privacy">Privacy</a></footer>
    </body></html>
    """

    @Test("Readability reduces a page to its article")
    func readability() async throws {
        let url = URL(string: "https://www.example.com/2024/speed-reading.html")!
        let result = try await run { emitter in try WebReader.readHTML(Self.page, url: url, into: emitter) }
        #expect(result.title == "How Speed Reading Works")
        #expect(result.paragraphs.contains { $0.hasPrefix("Rapid serial visual presentation") })
        #expect(result.paragraphs.last?.hasSuffix("sit unread in a queue forever.") == true, "\(result.outline)")
        for junk in ["Trending", "Celebrity", "World", "First!", "rights reserved", "Privacy"] {
            #expect(!result.text.contains(junk), "\(junk)\n\(result.outline)")
        }
        let image = try #require(result.images.first)
        #expect(image.url?.absoluteString == "https://www.example.com/images/rsvp-diagram.png")
        #expect(image.caption == "Where the eye rests")
    }

    @Test("When Readability finds nothing, the page is walked without its chrome")
    func fallback() async throws {
        let html = "<html><head><title>Tiny</title></head><body><nav>Menu</nav><p>Just one short line.</p><footer>Foot</footer></body></html>"
        let result = try await run { emitter in try WebReader.readHTML(html, url: URL(string: "https://example.com/")!, into: emitter) }
        #expect(result.paragraphs == ["Just one short line."])
        #expect(result.title == "Tiny")
    }

    @Test("Readability script loads from the bundle")
    func bundledScripts() throws {
        let article = Readability.extract(wellFormedHTML: HTMLParser.parse(Self.page).wellFormedDocument(), url: URL(string: "https://example.com/x"))
        #expect(article != nil)
        #expect((article?.textLength ?? 0) > 400)
    }
}
